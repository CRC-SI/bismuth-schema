EntityUtils =

  _footprintProperty: 'space.geom_2d'
  _meshProperty: 'space.geom_3d'

  toGeoEntityArgs: (id, args) ->
    df = Q.defer()
    model = Entities.findOne(id)
    typeId = SchemaUtils.getParameterValue(model, 'general.type')
    type = Typologies.findOne(typeId)
    typeFillColor = type && SchemaUtils.getParameterValue(type, 'style.fill_color')
    typeBorderColor = type && SchemaUtils.getParameterValue(type, 'style.border_color')
    AtlasConverter.getInstance().then(
      Meteor.bindEnvironment (converter) =>
        style = model.parameters.style
        fill_color = style?.fill_color ? typeFillColor ? '#eee'
        border_color = style?.border_color ? typeBorderColor
        if fill_color and !border_color
          border_color = Colors.darken(fill_color)
        space = model.parameters.space ? {}
        entity = Entities.findOne(id)
        geom_2d = @_getFootprint(entity)
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
    collectionId = id + '-' + paramId
    df = Q.defer()
    @_getGeometryFromFile(id, paramId).then(
      Meteor.bindEnvironment (geom) ->
        df.resolve(GeometryUtils.buildGeometryFromC3ml(geom, {collectionId: collectionId}))
      df.reject
    )
    df.promise

  _render2dGeometry: (id) ->
    entity = Entities.findOne(id)
    footprint = @_getFootprint(entity)
    unless footprint
      return Q.when(null)
    df = Q.defer()
    WKT.getWKT Meteor.bindEnvironment (wkt) =>
      isWKT = wkt.isWKT(footprint)
      if isWKT
        # Hidden by default since we change the display mode to toggle visibility.
        @toGeoEntityArgs(id, {show: false}).then Meteor.bindEnvironment (entityArgs) =>
          geoEntity = AtlasManager.renderEntity(entityArgs)
          df.resolve(geoEntity)
      else
        @_buildGeometryFromFile(id, @_footprintProperty).then(df.resolve, df.reject)
    df.promise

  _render3dGeometry: (id) -> @_buildGeometryFromFile(id, @_meshProperty)

  _getFootprint: (entity) -> SchemaUtils.getParameterValue(entity, @_footprintProperty)

  _getMesh: (entity) -> SchemaUtils.getParameterValue(entity, @_meshProperty)

  enableRendering: (enabled) ->
    return if enabled == renderingEnabled
    df = @renderingEnabledDf
    if enabled
      Logger.debug('Enabling rendering')
      if @prevRenderingEnabledDf
        @prevRenderingEnabledDf.resolve()
        @prevRenderingEnabledDf = null
      df.resolve()
    else
      Logger.debug('Disabling rendering')
      # Prevent existing deferred renders from beign rejected by resuming them once rendering is
      # enabled.
      if Q.isPending(df.promise)
        @prevRenderingEnabledDf = df
      @renderingEnabledDf = Q.defer()
    renderingEnabled = enabled

  isRenderingEnabled: -> @renderingEnabled

  render: (id, args) ->
    df = Q.defer()
    @renderingEnabledDf.promise.then Meteor.bindEnvironment =>
      @renderQueue.add id, => @_render(id, args).then(df.resolve, df.reject)
    df.promise

  _render: (id, args) ->
    df = Q.defer()
    @incrementRenderCount()
    df.promise.fin => @decrementRenderCount()
    model = Entities.findOne(id)
    geom_2d = @_getFootprint(model)
    geom_3d = @_getFootprint(model)
    isCollection = Entities.getChildren(id).count() > 0

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
      df.resolve(AtlasManager.createCollection(id, {children: []}))
    else
      requirejs ['atlas/model/Feature'], Meteor.bindEnvironment (Feature) =>
        WKT.getWKT Meteor.bindEnvironment (wkt) =>
          isWKT = wkt.isWKT(geom_2d)
          Q.all([@_render2dGeometry(id), @_render3dGeometry(id)]).then(
            Meteor.bindEnvironment (geometries) =>
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
                  Meteor.bindEnvironment (args) ->
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
                Meteor.bindEnvironment (geoEntity) =>
                  if entity3d
                    geoEntity.setForm(Feature.DisplayMode.MESH, entity3d)
                  df.resolve(geoEntity)
                df.reject
              )
            df.reject
          )
    df.promise.then Meteor.bindEnvironment (geoEntity) =>
      return unless geoEntity
      # TODO(aramk) Rendering the parent as a special case with children doesn't affect the
      # visualisation at this point.
      # Render the parent but don't delay the entity to prevent a deadlock with the render
      # queue.
      displayMode = args?.displayMode ? @getDisplayMode(id)
      # Set the display mode on features - entities which are collections do not apply.
      if geoEntity.setDisplayMode? && displayMode
        geoEntity.setDisplayMode(displayMode)
      parentId = model.parent
      if parentId
        @render(parentId).then (parentEntity) =>
          unless geoEntity.getParent()
            # TODO(aramk) addEntity() may not be defined in the parent if it isn't a collection.
            # Atlas doesn't support any GeoEnity having support for adding children.
            parentEntity.addEntity?(id)
          @show(parentId)
      # Setting the display mode isn't enough to show the entity if we rendered a hidden geometry.
      @show(id)
    df.promise.fail ->
      # Remove any entities which failed to render to avoid leaving them within Atlas.
      Logger.error('Failed to render entity ' + id)
      _.each addedGeometry, (geometry) -> geometry.remove()
    df.promise

  renderAll: (args) ->
    df = Q.defer()
    @renderingEnabledDf.promise.then Meteor.bindEnvironment =>
      # renderDfs = []
      # models = Entities.findByProject().fetch()
      @_chooseDisplayMode()
      # _.each models, (model) => renderDfs.push(@render(model._id))
      # df.resolve(Q.all(renderDfs))
      promise = @renderQueue.add 'bulk', => @_renderBulk(args)
      df.resolve(promise)
    df.promise

  _renderBulk: (args)  ->
    args ?= {}
    df = Q.defer()
    ids = args.ids
    if ids
      entities = _.map ids, (id) -> Entities.findOne(id)
    else
      projectId = args.projectId ? Projects.getCurrentId()
      entities = Entities.findByProject(projectId).fetch()
    
    childrenIdMap = {}
    _.each ids, (id) ->
      childrenIdMap[id] = Entities.find({parent: id}).map (entity) -> entity._id

    promises = []
    WKT.getWKT Meteor.bindEnvironment (wkt) =>
      c3mlEntities = []

      _.each entities, (entity) =>
        id = AtlasIdMap.getAtlasId(entity._id)
        geom2dId = null
        geom3dId = null
        geoEntity = AtlasManager.getEntity(id)
        if geoEntity?
          # Ignore already rendered entities.
          return

        displayMode = @getDisplayMode(entity._id)

        geom_2d = @_getFootprint(entity)
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

          c3ml = @toC3mlArgs(id)
          _.extend c3ml,
            id: id + '-geom2d'
            coordinates: geom_2d
          
          if wkt.isPolygon(geom_2d)
            c3ml.type = 'polygon'
          else if wkt.isLine(geom_2d)
            c3ml.type = 'line'
          else if wkt.isPoint(geom_2d)
            c3ml.type = 'point'
          else
            console.error('Could not render unknown format of WKT', geom_2d)
            return

          if fill_color
            c3ml.color = fill_color
          if border_color
            c3ml.borderColor = border_color
          c3mlEntities.push(c3ml)
        
        geom_3d = @_getMesh(entity)
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
            # 3D mesh is a file reference, so render it individually.
            promises.push @render(id)
            return

        if geom2dId || geom3dId
          forms = {}
          if geom2dId
            forms[@getFormType2d(id)] = geom2dId
          if geom3dId
            forms.mesh = geom3dId
          c3mlEntities.push
            id: id
            type: 'feature'
            displayMode: displayMode
            forms: forms
        else if childrenIdMap[id]
          c3mlEntities.push
            id: id
            type: 'collection'
            children: childrenIdMap[id]

      promises.push AtlasManager.renderEntities(c3mlEntities)
      Q.all(promises).then(
        Meteor.bindEnvironment (results) ->
          c3mlEntities = []
          _.each results, (result) ->
            if Types.isArray(result)
              _.each result, (singleResult) -> c3mlEntities.push(singleResult)
            else
              c3mlEntities.push(result)
          df.resolve(c3mlEntities)
        df.reject
      )
    df.promise

  renderAllAndZoom: ->
    df = Q.defer()
    @renderAll().then(
      Meteor.bindEnvironment (c3mlEntities) =>
        df.resolve(c3mlEntities)
        if c3mlEntities.length == 0
          ProjectUtils.zoomTo()
        else
          # If no entities have geometries, this will fail, so we should zoom to the project if
          # possible.
          @zoomToEntities()
      df.reject
    )
    df.promise

  whenRenderingComplete: -> @renderQueue.waitForAll()

  _chooseDisplayMode: ->
    geom2dCount = 0
    geom3dCount = 0
    Entities.findByProject(Projects.getCurrentId()).forEach (entity) =>
      footprint = @_getFootprint(entity)
      mesh = @_getMesh(entity)
      if footprint
        geom2dCount++
      if mesh
        geom3dCount++
    displayMode = if geom3dCount > geom2dCount then 'mesh' else 'extrusion'
    Session.set(displayModeSessionVariable, displayMode)

  zoomToEntity: (id) ->
    geoEntity = AtlasManager.getEntity(id)
    return unless geoEntity
    centroid = geoEntity.getCentroid()
    centroid.elevation = 1000
    AtlasManager.zoomTo({position: centroid, duration: 1000})

  zoomToEntities: (ids) ->
    ids ?= Entities.findByProject().map (entity) -> entity._id
    if ids.length != 0
      # If no entities have geometries, this will fail, so we should zoom to the project if
      # possible.
      AtlasManager.zoomToEntities(ids).fail(-> ProjectUtils.zoomTo()).done()
    else
      Q.when(ProjectUtils.zoomTo())

  _renderEntity: (id, args) ->
    df = Q.defer()
    @toGeoEntityArgs(id, args).then(
      Meteor.bindEnvironment (entityArgs) ->
        unless entityArgs
          console.error('Cannot render - no entityArgs')
          return
        df.resolve(AtlasManager.renderEntity(entityArgs))
      df.reject
    )
    df.promise

  unrender: (id) ->
    df = Q.defer()
    @renderingEnabledDf.promise.then Meteor.bindEnvironment =>
      @renderQueue.add id, ->
        AtlasManager.unrenderEntity(id)
        df.resolve(id)
    df.promise

  show: (id) ->
    if AtlasManager.showEntity(id)
      ids = @_getChildrenFeatureIds(id)
      ids.push(id)
      PubSub.publish('entity/show', {ids: ids})

  hide: (id) ->
    return unless AtlasManager.getEntity(id)
    if AtlasManager.hideEntity(id)
      ids = @_getChildrenFeatureIds(id)
      ids.push(id)
      PubSub.publish('entity/hide', {ids: ids})

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
    
    # renderedIds = []
    # promises = []
    df = Q.defer()

    entities = Entities.findByProjectAndScenario(projectId, scenarioId).fetch()
    existingEntities = {}
    ids = _.map entities, (entity) -> entity._id
      # AtlasManager
      # existingEntities[]
    if Meteor.isServer
      # Unrender all entities when on the server to prevent using old rendered data.
      unrenderPromises = _.map ids, (id) => @unrender(id)
    else
      unrenderPromises = []
    Q.all(unrenderPromises).then Meteor.bindEnvironment =>
      renderPromise = @_renderBulk({ids: ids, projectId: projectId})
      renderPromise.then -> 
        geoEntities = _.map ids, (id) -> AtlasManager.getEntity(id)
        _.each geoEntities, (entity) ->
          addEntity(entity)
          _.each entity.getRecursiveChildren(), addEntity
        _.each entitiesJson, (json) -> json.type = json.type.toUpperCase()
        df.resolve(c3mls: entitiesJson)
      # Unrender all entities when on the server to prevent using old rendered data.
      renderPromise.fin Meteor.bindEnvironment => if Meteor.isServer then _.each ids, (id) => @unrender(id)
    df.promise

    # entities = _.filter entities, (entity) -> !entity.parent
    # _.each entities, (entity) =>
    #   id = entity._id
    #   entityPromises = []
    #   if Meteor.isServer
    #     entityPromises.push @unrender(id)
    #   entityPromises.push @render(id, args)
    #   promises.push Q.all(entityPromises).then (result) ->
    #     geoEntity = result[1]
    #     return unless geoEntity
    #     addEntity(geoEntity)
    #     _.each geoEntity.getRecursiveChildren(), (childEntity) -> addEntity(childEntity)
    # promise = Q.all(promises)
    
    # promise = df.promise
    # promise.then ->
    #   _.each entitiesJson, (json) -> json.type = json.type.toUpperCase()
    #   {c3mls: entitiesJson}
    # promise.fin =>
    #   if Meteor.isServer
    #     _.each renderedIds, (id) => @unrender(id)
      # Remove all rendered entities so they aren't cached on the next request.

  _getProjectAndScenarioArgs: (args) ->
    args ?= {}
    args.projectId ?= Projects.getCurrentId()
    if args.scenarioId == undefined
      args.scenarioId = ScenarioUtils.getCurrentId()
    args

  downloadInBrowser: (projectId, scenarioId) ->
    projectId ?= Projects.getCurrentId()
    scenarioId ?= ScenarioUtils.getCurrentId()
    Logger.info('Download entities as KMZ', projectId, scenarioId)
    Meteor.call 'entities/to/kmz', projectId, scenarioId, (err, fileId) =>
      if err then throw err
      if fileId
        Logger.info('Download entities as KMZ with file ID', fileId)
        Files.downloadInBrowser(fileId)
      else
        Logger.error('Could not download entities.')

  incrementRenderCount: -> @renderCount.set(@renderCount.get() + 1)

  decrementRenderCount: -> @renderCount.set(@renderCount.get() - 1)

  getRenderCount: -> @renderCount.get()

  resetRenderCount: -> @renderCount.set(0)

  beforeAtlasUnload: -> @reset()

  reset: ->
    @renderingEnabled = true
    @renderCount = new ReactiveVar(0)
    @renderQueue = new DeferredQueueMap()
    @renderingEnabledDf = Q.defer()
    @renderingEnabledDf.resolve()
    @prevRenderingEnabledDf = null

Meteor.startup -> EntityUtils.reset()

WKT.getWKT Meteor.bindEnvironment (wkt) ->
  _.extend EntityUtils,

    getFormType2d: (id) ->
      model = Entities.findOne(id)
      space = model.parameters.space
      geom_2d = space?.geom_2d
      # Entities which have line or point geometries cannot have extrusion or mesh display modes.
      if wkt.isPolygon(geom_2d)
        'polygon'
      else if wkt.isLine(geom_2d)
        'line'
      else if wkt.isPoint(geom_2d)
        'point'
      else
        null

    getDisplayMode: (id) ->
      formType2d = @getFormType2d(id)
      if formType2d != 'polygon'
        # When rendering lines and points, ensure the display mode is consistent. With polygons,
        # we only enable them if 
        formType2d
      else if Meteor.isClient
        Session.get(displayModeSessionVariable)
      else
        # Server-side cannot display anything.
        null

if Meteor.isServer

  _.extend EntityUtils,

    convertToKmz: (args) ->
      Logger.info('Converting entities to KMZ', args)
      args = @_getProjectAndScenarioArgs(args)
      projectId = args.projectId
      scenarioId = args.scenarioId

      scenarioStr = if scenarioId then '-' + scenarioId else ''
      filePrefix = ProjectUtils.getDatedIdentifier(projectId) + scenarioStr
      filename = filePrefix + '.kmz'

      c3mlData = Promises.runSync -> EntityUtils.getEntitiesAsJson(args)
      Logger.info('Wrote C3ML entities to', FileLogger.log(c3mlData))
      if c3mlData.c3mls.length == 0
        throw new Error('No entities to convert')
      buffer = AssetConversionService.export(c3mlData)
      
      file = new FS.File()
      file.name(filename)
      file.attachData(Buffers.toArrayBuffer(buffer), type: 'application/vnd.google-earth.kmz')
      file = Promises.runSync -> Files.upload(file)
      file._id

  Meteor.methods
    'entities/to/json': (projectId, scenarioId) ->
      Promises.runSync -> EntityUtils.getEntitiesAsJson
        projectId: projectId
        scenarioId: scenarioId
    'entities/to/kmz': (projectId, scenarioId) ->
      EntityUtils.convertToKmz
        projectId: projectId
        scenarioId: scenarioId
