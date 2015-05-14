bindMeteor = Meteor.bindEnvironment.bind(Meteor)
displayModeSessionVariable = 'entityDisplayMode'

renderCount = new ReactiveVar(0)
incrementRenderCount = -> renderCount.set(renderCount.get() + 1)
decrementRenderCount = -> renderCount.set(renderCount.get() - 1)

_renderQueue = null
_uploadQueue = null
resetRenderQueue = -> _renderQueue = new DeferredQueueMap()
resetUploadQueue = -> _uploadQueue = new DeferredQueue()
renderingEnabled = true
renderingEnabledDf = Q.defer()
renderingEnabledDf.resolve()
prevRenderingEnabledDf = null
Meteor.startup ->
  resetRenderQueue()
  resetUploadQueue()

EntityUtils =

  fromAsset: (args) ->
    # Log the asset conversion when executing from the server to aid debugging.
    if Meteor.isServer
      filename = 'asset' + Dates.toIdentifier(moment()) + '.json'
      filePath = FileUtils.writeToTempFile(filename, JSON.stringify(args))
      Logger.info('Wrote asset to', filePath)

    df = Q.defer()
    modelDfs = []
    c3mls = args.c3mls
    colorOverride = args.color
    isLayer = args.isLayer
    projectId = args.projectId ? Projects.getCurrentId()
    unless projectId
      throw new Error('No project provided.')

    if isLayer
      layerPromise = LayerUtils.fromC3mls c3mls,
        projectId: projectId
        name: args.filename ? c3mls[0].id
      modelDfs.push(layerPromise)
    else
      insertedCount = 0
      # A map of type names to deferred promises for creating them. Used to prevent a race condition
      # if we try to create the types with two entities. In this case, the second request should use
      # the existing type promise.
      typePromiseMap = {}

      # Colors that are assigned to newly created typologies which should be excluded from the
      # the next set of available colors. Since types are created asychronously
      # getNextAvailableColor() won't know to exclude the used colors until the insert is complete.
      usedColors = []

      # A map of c3ml IDs to entity IDs used for finding the parentId of the entity model
      # corresponding to that of the c3ml entity.
      # idMap = {}

      # Edges formed from the entity graph which is used to topsort so we create children after
      # their parents and set the parentId field based on idMap.
      edges = []

      # A map of c3ml IDs for entities which are part of the topsort. Any c3ml not in this list is
      # added to the list of sorted ids after topsort is executed.
      sortMap = {}

      # A map of c3ml IDs to the c3ml entities which is used for lookups once the order of creation
      # has been decided.
      c3mlMap = {}

      # A map of c3ml IDs to promises of geometry arguments.
      geomDfMap = {}

      # A map of c3ml IDs to deferred promises of their model IDs.
      entityDfMap = {}

      getOrCreateTypologyByName = (name) ->
        typePromise = typePromiseMap[name]
        return typePromise if typePromise
        typeDf = Q.defer()
        typePromiseMap[name] = typeDf.promise
        type = Typologies.findByName(name, projectId)
        if type
          typeDf.resolve(type._id)
        else
          fillColor = Typologies.getNextAvailableColor(projectId, {exclude: usedColors})
          usedColors.push(fillColor)
          typologyDoc =
            name: name
            project: projectId
            parameters:
              style:
                fill_color: fillColor
          Typologies.insert typologyDoc, (err, typeId) ->
            if err
              typeDf.reject(err)
            else
              typeDf.resolve(typeId)
        typeDf.promise

      _.each c3mls, (c3ml, i) ->
        entityId = c3ml.id
        c3mlMap[entityId] = c3ml
        entityParams = c3ml.properties ? {}
        modelDf = Q.defer()
        modelDfs.push(modelDf.promise)
        entityDfMap[entityId] = modelDf
        geomDf = Q.defer()
        geomDfMap[entityId] = geomDf.promise
        type = AtlasConverter.sanitizeType(c3ml.type)
        parentId = c3ml.parentId
        if parentId
          edges.push([parentId, entityId])
          sortMap[parentId] = sortMap[entityId] = true
        # Create a pseudo-filename so the data is detected as a File rather than serialized JSON or
        # WKT.
        filename = entityId + '.json'
        if type == 'mesh'
          c3mlStr = JSON.stringify({c3mls: [c3ml]})
          geomDf.resolve(geom_3d: c3mlStr, geom_3d_filename: filename)
        else if type == 'collection'
          # Ignore collection since it only contains children c3ml IDs.
          geomDf.resolve(null)
        else
          WKT.fromC3ml(c3ml).then(
            (wkt) ->
              geomArgs = null
              if wkt
                geomArgs = {geom_2d: wkt, geom_2d_filename: filename}
              geomDf.resolve(geomArgs)
            geomDf.reject
          )

      # Add any entities which are not part of a hierarchy and weren't in the topological sort.
      sortedIds = topsort(edges)
      _.each c3mls, (c3ml) ->
        id = c3ml.id
        unless sortMap[id]
          sortedIds.push(id)

      Q.all(_.values(geomDfMap)).then(
        bindMeteor ->
          _.each sortedIds, (c3mlId, c3mlIndex) ->
            c3ml = c3mlMap[c3mlId]
            entityParams = c3ml.properties ? {}
            height = entityParams.height ? entityParams.Height ? entityParams.HEIGHT ?
              entityParams.ROOMHEIGHT ? c3ml.height
            elevation = entityParams.Elevation ? entityParams.FLOORRL ? c3ml.altitude
            Q.when(geomDfMap[c3mlId]).then bindMeteor (geomArgs) ->
              # geomArgs = geomDfMap[c3mlId]
              # Geometry may be empty
              space = null
              if geomArgs
                space = _.extend geomArgs,
                  height: height
                  elevation: elevation
              typeName = null
              inputs = {}
              _.each entityParams, (value, name) ->
                value = parseFloat(value)
                inputs[name] = value unless isNaN(value)
              _.each ['Type', 'TYPE', 'type', 'landuse'], (typeParam) ->
                typeValue = entityParams[typeParam]
                typeName = entityParams[typeParam] if typeValue?
                delete inputs[typeParam]

              createEntity = bindMeteor (typeId) ->
                # Wait until the parent is inserted so we can reference its ID. Use Q.when() in case
                # there is no parent.
                Q.when(entityDfMap[c3ml.parentId]?.promise).then bindMeteor (parentId) ->
                  modelDf = entityDfMap[c3mlId]
                  if colorOverride
                    fillColor = colorOverride
                  # If type is provided, don't use c3ml default color and only use param values if
                  # they exist to override the type color.
                  fillColor = entityParams.FILLCOLOR ? (!typeId && c3ml.color)
                  borderColor = entityParams.BORDERCOLOR ? (!typeId && c3ml.borderColor)
                  AtlasConverter.getInstance().then bindMeteor (converter) ->
                    getDefaultName = 'Entity ' + (c3mlIndex + 1)
                    name = c3ml.name ? entityParams.Name ? entityParams.NAME ?
                      entityParams.BUILDINGKE ? entityParams.name ? getDefaultName
                    if fillColor
                      fill_color = converter.colorFromC3mlColor(fillColor).toString()
                    if borderColor
                      border_color = converter.colorFromC3mlColor(borderColor).toString()
                    model =
                      name: name
                      project: projectId
                      parent: parentId
                      parameters:
                        general:
                          type: typeId
                        space: space
                        style:
                          fill_color: fill_color
                          border_color: border_color
                        inputs: inputs
                    Entities.insert model, (err, insertId) ->
                      if err
                        console.error('Failed to insert entity', err)
                        modelDf.reject(err)
                      else
                        # idMap[c3mlId] = insertedId
                        insertedCount++
                        if insertedCount % 100 == 0 || insertedCount == c3mls.length
                          Logger.debug('Inserted ' + insertedCount + '/' + c3mls.length +
                              ' entities')
                        modelDf.resolve(insertId)

              if typeName
                getOrCreateTypologyByName(typeName).then(createEntity)
              else
                createEntity(null)
        df.reject
      )

    Q.all(modelDfs).then(
      bindMeteor ->
        requirejs ['atlas/model/GeoPoint'], bindMeteor (GeoPoint) ->
          importCount = modelDfs.length
          resolve = -> df.resolve(importCount)
          Logger.info 'Imported ' + importCount + ' entities'
          if isLayer
            # Importing layers should not affect the location of the project.
            resolve()
            return
          # If the project doesn't have lat, lng location, set it as that found in this file.
          location = Projects.getLocationCoords(projectId)
          if location.latitude? && location.longitude?
            resolve()
          else
            assetPosition = null
            _.some c3mls, (c3ml) ->
              position = c3ml.coordinates[0] ? c3ml.geoLocation
              if position
                assetPosition = new GeoPoint(position)
            if assetPosition?
              console.log 'Setting project location', assetPosition
              Projects.setLocationCoords(projectId, assetPosition).then(resolve, df.reject)
            else
              resolve()
      df.reject
    )
    df.promise

  toGeoEntityArgs: (id, args) ->
    df = Q.defer()
    model = @_getModel(id)
    typeId = SchemaUtils.getParameterValue(model, 'general.type')
    type = Typologies.findOne(typeId)
    typeFillColor = type && SchemaUtils.getParameterValue(type, 'style.fill_color')
    typeBorderColor = type && SchemaUtils.getParameterValue(type, 'style.border_color')
    AtlasConverter.getInstance().then(
      bindMeteor (converter) =>
        style = model.parameters.style
        fill_color = style?.fill_color ? typeFillColor ? '#eee'
        border_color = style?.border_color ? typeBorderColor
        if fill_color and !border_color
          border_color = Colors.darken(fill_color)
        space = model.parameters.space ? {}
        geom_2d = space.geom_2d
        unless geom_2d
          geom_2d = null
          # throw new Error('No 2D geometry - cannot render entity with ID ' + id)
        displayMode = args?.displayMode ? @getDisplayMode(id)
        args = Setter.merge({
          id: id
          vertices: geom_2d
          elevation: space.elevation
          displayMode: displayMode
          style:
            fillColor: fill_color
            borderColor: border_color
        }, args)
        height = space.height
        if height?
          args.height = height
        result = converter.toGeoEntityArgs(args)
        df.resolve(result)
      df.reject
    )
    df.promise

  toC3mlArgs: (id) ->
    entity = Entities.findOne(id)
    args = {}
    elevation = SchemaUtils.getParameterValue(entity, 'space.elevation')
    height = SchemaUtils.getParameterValue(entity, 'space.height')
    fill_color = SchemaUtils.getParameterValue(entity, 'style.fill_color')
    border_color = SchemaUtils.getParameterValue(entity, 'style.border_color')
    if height? then args.height = height
    if elevation? then args.altitude = elevation
    if fill_color? then args.color = fill_color
    if border_color? then args.borderColor = border_color
    args

  _getGeometryFromFile: (id, paramId) ->
    paramId ?= 'geom_3d'
    entity = Entities.findOne(id)
    value = SchemaUtils.getParameterValue(entity, 'space.' + paramId)
    unless value then return Q.resolve(null)
    # Attempt to parse the value as JSON. If it fails, treat it as a file ID.
    try
      return Q.resolve(JSON.parse(value))
    catch
      # Do nothing
    Files.downloadJson(value)

  _buildGeometryFromFile: (id, paramId) ->
    # paramId ?= 'geom_3d'
    # entity = Entities.findOne(id)
    # fileId = SchemaUtils.getParameterValue(entity, 'space.' + paramId)
    # unless fileId
    #   return Q.when(null)
    # GeometryUtils.buildGeometryFromFile(fileId, {collectionId: collectionId})
    collectionId = id + '-' + paramId
    df = Q.defer()
    @_getGeometryFromFile(id, paramId).then(
      (geom) ->
        df.resolve(GeometryUtils.buildGeometryFromC3ml(geom, {collectionId: collectionId}))
      df.reject
    )
    df.promise

  _render2dGeometry: (id) ->
    entity = Entities.findOne(id)
    geom_2d = SchemaUtils.getParameterValue(entity, 'space.geom_2d')
    unless geom_2d
      return Q.when(null)
    df = Q.defer()
    WKT.getWKT bindMeteor (wkt) =>
      isWKT = wkt.isWKT(geom_2d)
      if isWKT
        # Hidden by default since we change the display mode to toggle visibility.
        @toGeoEntityArgs(id, {show: false}).then bindMeteor (entityArgs) =>
          geoEntity = AtlasManager.renderEntity(entityArgs)
          df.resolve(geoEntity)
      else
        @_buildGeometryFromFile(id, 'geom_2d').then(df.resolve, df.reject)
    df.promise

  _render3dGeometry: (id) -> @_buildGeometryFromFile(id, 'geom_3d')

  getDisplayMode: (id) ->
    model = Entities.findOne(id)
    space = model.parameters.space
    geom_2d = space?.geom_2d
    # Entities which have line geometries cannot have extrusion or mesh display modes.
    isLine = geom_2d && geom_2d.indexOf('LINESTRING') >= 0
    if isLine
      'line'
    else if Meteor.isClient
      Session.get(displayModeSessionVariable)
    else
      # Server-side cannot display anything.
      null

  _getModel: (id) -> Entities.findOne(id)

  enableRendering: (enabled) ->
    return if enabled == renderingEnabled
    df = renderingEnabledDf
    if enabled
      Logger.debug('Enabling rendering')
      if prevRenderingEnabledDf
        prevRenderingEnabledDf.resolve()
        prevRenderingEnabledDf = null
      df.resolve()
    else
      Logger.debug('Disabling rendering')
      # Prevent existing deferred renders from beign rejected by resuming them once rendering is
      # enabled.
      if Q.isPending(df.promise)
        prevRenderingEnabledDf = df
      renderingEnabledDf = Q.defer()
    renderingEnabled = enabled

  render: (id, args) ->
    df = Q.defer()
    renderingEnabledDf.promise.then bindMeteor =>
      _renderQueue.add id, => @_render(id, args).then(df.resolve, df.reject)
    df.promise

  _render: (id, args) ->
    df = Q.defer()
    incrementRenderCount()
    df.promise.fin -> decrementRenderCount()
    model = @_getModel(id)
    space = model.parameters.space
    geom_2d = space?.geom_2d
    geom_3d = space?.geom_3d
    isCollection = Entities.getChildren(id).count() > 0
    displayMode = args?.displayMode
    if Meteor.isClient
      displayMode ?= Session.get(displayModeSessionVariable)

    unless geom_2d || geom_3d || isCollection
      df.resolve(null)
      return df.promise
    geoEntity = AtlasManager.getEntity(id)
    exists = geoEntity?
    # All the geometry added during rendering. If rendering fails, these are all discarded.
    addedGeometry = []
    if exists
      @show(id)
      df.resolve(geoEntity)
    else if isCollection
      # Collections are rendered as empty collections. Once children are rendered, they add
      # themselves to the parent.
      df.resolve(AtlasManager.createCollection(id, {
        children: []
        groupSelect: false
      }))
    else
      requirejs ['atlas/model/Feature'], bindMeteor (Feature) =>
        WKT.getWKT bindMeteor (wkt) =>
          isWKT = wkt.isWKT(geom_2d)
          Q.all([@_render2dGeometry(id), @_render3dGeometry(id)]).then(
            bindMeteor (geometries) =>
              entity2d = geometries[0]
              entity3d = geometries[1]
              unless entity2d || entity3d
                df.resolve(null)
                return

              # This feature will be used for rendering the 2d geometry as the
              # footprint/extrusion and the 3d geometry as the mesh.
              geoEntityDf = Q.defer()
              if isWKT
                geoEntityDf.resolve(entity2d)
              else
                # If we construct the 2d geometry from a collection of entities rather than
                # WKT, the geometry is a collection rather than a feature. Create a new
                # feature to store both 2d and 3d geometries.
                @toGeoEntityArgs(id, {vertices: null}).then(
                  bindMeteor (args) ->
                    geoEntity = AtlasManager.renderEntity(args)
                    addedGeometry.push(geoEntity)
                    if entity2d
                      geoEntity.setForm(Feature.DisplayMode.FOOTPRINT, entity2d)
                      args.height? && entity2d.setHeight(args.height)
                      args.elevation? && entity2d.setElevation(args.elevation)
                    geoEntityDf.resolve(geoEntity)
                  geoEntityDf.reject
                )
              geoEntityDf.promise.then(
                bindMeteor (geoEntity) =>
                  if entity3d
                    geoEntity.setForm(Feature.DisplayMode.MESH, entity3d)
                  df.resolve(geoEntity)
                df.reject
              )
            df.reject
          )
    df.promise.then bindMeteor (geoEntity) =>
      return unless geoEntity
      # TODO(aramk) Rendering the parent as a special case with children doesn't affect the
      # visualisation at this point.
      # # Render the parent but don't delay the entity to prevent a deadlock with the render
      # # queue.
      # parentId = model.parent
      # # Set the display mode on features - entities which are collections do not apply.
      # if geoEntity.setDisplayMode? && displayMode
      #   geoEntity.setDisplayMode(displayMode)
      # if parentId
      #   @render(parentId).then (parentEntity) =>
      #     unless geoEntity.getParent()
      #       parentEntity.addEntity(id)
      #     @show(parentId)
      # else
      # Setting the display mode isn't enough to show the entity if we rendered a hidden geometry.
      @show(id)
    df.promise.fail ->
      # Remove any entities which failed to render to avoid leaving them within Atlas.
      console.error('Failed to render entity ' + id)
      _.each addedGeometry, (geometry) -> geometry.remove()
    df.promise

  renderAll: ->
    df = Q.defer()
    renderingEnabledDf.promise.then bindMeteor =>
      # renderDfs = []
      # models = Entities.findByProject().fetch()
      @_chooseDisplayMode()
      # _.each models, (model) => renderDfs.push(@render(model._id))
      # df.resolve(Q.all(renderDfs))
      df.resolve(@_renderBulk())
    df.promise

  _renderBulk: ->
    # TODO(aramk) Remove - just for testing.
    # return Q.resolve([])

    df = Q.defer()
    entities = Entities.findByProject().fetch()
    project = Projects.getCurrent()
    WKT.getWKT (wkt) =>
      c3mlEntities = []

      _.each entities, (entity) =>
        id = AtlasIdMap.getAtlasId(entity._id)
        geom2dId = null
        geom3dId = null
        geoEntity = AtlasManager.getEntity(id)
        if geoEntity?
          # Ignore already rendered entities.
          return

        geom_2d = SchemaUtils.getParameterValue(entity, 'space.geom_2d')
        if geom_2d
          geom2dId = id + '-geom2d'

          typeId = SchemaUtils.getParameterValue(entity, 'general.type')
          type = Typologies.findOne(typeId)
          typeFillColor = type && SchemaUtils.getParameterValue(type, 'style.fill_color')
          typeBorderColor = type && SchemaUtils.getParameterValue(type, 'style.border_color')
          style = SchemaUtils.getParameterValue(entity, 'style')
          fill_color = style?.fill_color ? typeFillColor ? '#eee'
          border_color = style?.border_color ? typeBorderColor
          if fill_color && !border_color
            border_color = Colors.darken(fill_color)

          # isWKT = wkt.isWKT(geom_2d)
          # if isWKT
          c3ml = @toC3mlArgs(id)
          _.extend c3ml,
            id: id + '-geom2d'
            type: 'polygon'
            coordinates: geom_2d
          if fill_color
            c3ml.color = fill_color
          if border_color
            c3ml.borderColor = border_color
          c3mlEntities.push(c3ml)
          # else
          #   Logger.error('Cannot render 2D geometry which is not WKT.')
        
        geom_3d = SchemaUtils.getParameterValue(entity, 'space.geom_3d')
        if geom_3d
          geom3dId = id + '-geom3d'
          try
            c3mls = JSON.parse(geom_3d).c3mls
            childIds = _.map c3mls, (c3ml) ->
              c3mlEntities.push(c3ml)
              c3ml.id
            c3mlEntities.push
              id: geom3dId
              type: 'collection'
              children: childIds
          catch e
            Logger.error('Could not render 3D geometry as C3ML', e)

        if geom2dId || geom3dId
          forms = {}
          if geom2dId
            forms.polygon = geom2dId
          if geom3dId
            forms.mesh = geom3dId
          displayMode = @getDisplayMode(entity._id)
          c3mlEntities.push
            id: id
            type: 'feature'
            displayMode: displayMode
            forms: forms

      df.resolve(AtlasManager.renderEntities(c3mlEntities))
    df.promise

  renderAllAndZoom: ->
    df = Q.defer()
    @renderAll().then(
      bindMeteor (c3mlEntities) =>
        df.resolve(c3mlEntities)
        if c3mlEntities.length == 0
          ProjectUtils.zoomTo()
        else
          # If no entities have geometries, this will fail, so we should zoom to the project if
          # possible.
          promise = @zoomToEntities()
          promise.fail(-> ProjectUtils.zoomTo()).done()
      df.reject
    )
    df.promise

  _chooseDisplayMode: ->
    geom2dCount = 0
    geom3dCount = 0
    Entities.findByProject(Projects.getCurrentId()).forEach (entity) ->
      space = entity.parameters.space ? {}
      if space.geom_2d
        geom2dCount++
      if space.geom_3d
        geom3dCount++
    displayMode = if geom3dCount > geom2dCount then 'mesh' else 'extrusion'
    Session.set(displayModeSessionVariable, displayMode)

  zoomToEntities: ->
    ids = _.map Entities.findByProject().fetch(), (entity) -> entity._id
    AtlasManager.zoomToEntities(ids)

  _renderEntity: (id, args) ->
    df = Q.defer()
    @toGeoEntityArgs(id, args).then(
      bindMeteor (entityArgs) ->
        unless entityArgs
          console.error('Cannot render - no entityArgs')
          return
        df.resolve(AtlasManager.renderEntity(entityArgs))
      df.reject
    )
    df.promise

  unrender: (id) ->
    df = Q.defer()
    renderingEnabledDf.promise.then bindMeteor ->
      _renderQueue.add id, ->
        AtlasManager.unrenderEntity(id)
        df.resolve(id)
    df.promise

  show: (id) ->
    if AtlasManager.showEntity(id)
      ids = @_getChildrenFeatureIds(id)
      ids.push(id)
      _.each ids, (id) -> PubSub.publish('entity/show', id)

  hide: (id) ->
    if AtlasManager.hideEntity(id)
      ids = @_getChildrenFeatureIds(id)
      ids.push(id)
      _.each ids, (id) -> PubSub.publish('entity/hide', id)

  _getChildrenFeatureIds: (id) ->
    entity = AtlasManager.getFeature(id)
    childIds = []
    _.each entity?.getChildren(), (child) ->
      childId = child.getId()
      child = AtlasManager.getFeature(childId)
      if child then childIds.push(childId)
    childIds

  getSelectedIds: ->
    # Use the selected entities, or all entities in the project.
    entityIds = AtlasManager.getSelectedFeatureIds()
    # Filter GeoEntity objects which are not project entities.
    _.filter entityIds, (id) -> Entities.findOne(id)

  beforeAtlasUnload: ->
    resetRenderQueue()
    @resetRenderCount()

  getRenderCount: -> renderCount.get()

  resetRenderCount: -> renderCount.set(0)

  getEntitiesAsJson: (args) ->
    args = @_getProjectAndScenarioArgs(args)
    projectId = args.projectId
    scenarioId = args.scenarioId
    entitiesJson = []
    jsonIds = []
    addEntity = (entity) ->
      id = entity.getId()
      return if jsonIds[id]
      json = jsonIds[id] = entity.toJson()
      entitiesJson.push(json)
    promises = []
    # Only find the root entities and render those, which will render their children.
    entities = Entities.findByProjectAndScenario(projectId, scenarioId).fetch()
    entities = _.filter entities, (entity) -> !entity.parent
    _.each entities, (entity) =>
      id = entity._id
      entityPromises = []
      if Meteor.isServer
        # Remove all rendered entities so they aren't cached on the next request.
        entityPromises.push @unrender(id)
      entityPromises.push @render(id, args)
      promises.push Q.all(entityPromises).then (result) ->
        geoEntity = result[1]
        return unless geoEntity
        addEntity(geoEntity)
        _.each geoEntity.getRecursiveChildren(), (childEntity) -> addEntity(childEntity)
    Q.all(promises).then ->
      _.each entitiesJson, (json) -> json.type = json.type.toUpperCase()
      {c3mls: entitiesJson}

  _getProjectAndScenarioArgs: (args) ->
    args ?= {}
    args.projectId ?= Projects.getCurrentId()
    if args.scenarioId == undefined
      args.scenarioId = ScenarioUtils.getCurrentId()
    args

  downloadInBrowser: (projectId, scenarioId) ->
    projectId ?= Projects.getCurrentId()
    scenarioId ?= ScenarioUtils.getCurrentId()
    Meteor.call 'entities/to/kmz', projectId, scenarioId, (err, fileId) =>
      if err then throw err
      Files.downloadInBrowser(fileId)

if Meteor.isServer

  _.extend EntityUtils,

    convertToKmz: (args) ->
      args = @_getProjectAndScenarioArgs(args)
      projectId = args.projectId
      scenarioId = args.scenarioId

      scenarioStr = if scenarioId then '-' + scenarioId else ''
      filename = ProjectUtils.getDatedIdentifier(projectId) + scenarioStr + '.kmz'

      c3mlData = Promises.runSync -> EntityUtils.getEntitiesAsJson(args)
      if c3mlData.c3mls.length == 0
        throw new Error('No entities to convert')
      buffer = AssetConversionService.export(c3mlData)
      
      file = new FS.File()
      file.name(filename)
      file.attachData(Buffers.toArrayBuffer(buffer), type: 'application/vnd.google-earth.kmz')
      file = Promises.runSync -> Files.upload(file)
      file._id

  Meteor.methods
    'entities/from/asset': (args) -> Promises.runSync -> EntityUtils.fromAsset(args)
    'entities/to/json': (projectId, scenarioId) ->
      Promises.runSync -> EntityUtils.getEntitiesAsJson
        projectId: projectId
        scenarioId: scenarioId
    'entities/to/kmz': (projectId, scenarioId) ->
      EntityUtils.convertToKmz
        projectId: projectId
        scenarioId: scenarioId