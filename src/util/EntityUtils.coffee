####################################################################################################
# AUXILIARY
####################################################################################################

bindMeteor = Meteor.bindEnvironment.bind(Meteor)
displayModeSessionVariable = 'entityDisplayMode'

renderCount = new ReactiveVar(0)
incrementRenderCount = -> renderCount.set(renderCount.get() + 1)
decrementRenderCount = -> renderCount.set(renderCount.get() - 1)

GEOMETRY_SIZE_LIMIT = 1024 * 1024 * 10 # 10MB
CONSOLE_LOG_SIZE_LIMIT = 1024 * 1024 # 1MB

renderQueue = null
uploadQueue = null
resetRenderQueue = -> renderQueue = new DeferredQueueMap()
resetUploadQueue = -> uploadQueue = new DeferredQueue()

renderingEnabled = true
renderingEnabledDf = Q.defer()
renderingEnabledDf.resolve()
prevRenderingEnabledDf = null

Meteor.startup ->
  resetRenderQueue()
  resetUploadQueue()

NameParamIds = ['Name', 'NAME', 'name']
TypeParamIds = ['Type', 'TYPE', 'type', 'landuse', 'use']
IfcTypeParamIds = ['space_code']
HeightParamIds = ['height', 'Height', 'HEIGHT', 'ROOMHEIGHT']
ElevationParamIds = ['Elevation', 'ELEVATION', 'elevation', 'FLOORRL']
FillColorParamIds = ['FILLCOLOR']
BorderColorParamIds = ['BORDERCOLOR']

# Get parameter value using one of the given parameter IDs. Remove all values for all 
# parameter IDs to prevent them appearing in the imported inputs, since the parameter will be used
# in the native schema.
popParam = (params, paramIds) ->
  value = null
  _.each paramIds, (paramId) ->
    value ?= params[paramId]
    delete params[paramId]
  value

####################################################################################################
# END AUXILIARY
####################################################################################################

EntityUtils =

  fromAsset: (args) ->
    info = {fileId: args.fileId}
    if args.c3mls
      info.c3mlsCount = args.c3mls.length
    Logger.info 'Importing entities from asset', info
    df = Q.defer()
    if args.c3mls
      c3mlsPromise = Q.resolve(args.c3mls)
    else if args.fileId
      if Meteor.isServer
        result = AssetUtils.fromFile(args.fileId, args)
        c3mlsPromise = Q.resolve(result.c3mls)
      else
        c3mlsPromise = AssetUtils.fromFile(args.fileId, args).then (result) -> result.c3mls
    else
      return Q.reject('Either c3mls or fileId must be provided to EntityUtils.fromAsset()')
    c3mlsPromise.fail(df.reject)
    c3mlsPromise.then bindMeteor (c3mls) =>
      df.resolve @fromC3mls(Setter.merge(args, {c3mls: c3mls}))
    df.promise

  fromC3mls: (args) ->
    c3mls = args.c3mls
    unless Types.isArray(c3mls)
      return Q.reject('C3ML not defined as an array.')

    Logger.info 'Importing entities from', c3mls.length, 'c3mls...'
    if Meteor.isServer then FileLogger.log(args)

    limit = args.limit
    if limit
      c3mls = c3mls.slice(0, limit)
      Logger.info 'Limited to', limit, 'entities...'

    projectId = args.projectId ? Projects.getCurrentId()
    unless projectId
      return Q.reject('No project provided.')

    df = Q.defer()
    modelDfs = []
    # Invalid parent entity references.
    missingParentsIdMap = {}
    isLayer = args.isLayer
    isIfc = AssetUtils.getExtension(args.filename) == 'ifc'
    if isLayer
      layerPromise = LayerUtils.fromC3mls c3mls,
        projectId: projectId
        name: args.filename ? c3mls[0].id
      modelDfs.push(layerPromise)
    else
      # A map of type names to deferred promises for creating them. Used to prevent a race condition
      # if we try to create the types with two entities. In this case, the second request should use
      # the existing type promise.
      typePromiseMap = {}
      # Colors that are assigned to newly created typologies which should be excluded from the
      # the next set of available colors. Since types are created asychronously
      # getNextAvailableColor() won't know to exclude the used colors until the insert is complete.
      usedColors = []
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
      # A map of parent IDs to a map of children names to their IDs.
      childrenNameMap = {}
      scheduler = new TaskScheduler()

      getOrCreateTypologyByName = (name) ->
        typePromise = typePromiseMap[name]
        return typePromise if typePromise
        Logger.debug('Creating type', name)
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

      Logger.info('Inserting ' + c3mls.length + ' c3mls...')

      insertedCount = 0
      incrementC3mlCount = ->
        insertedCount++
        if insertedCount % 100 == 0 || insertedCount == c3mls.length
          Logger.debug('Inserted ' + insertedCount + '/' + c3mls.length + ' entities')

      geometryCount = 0
      incrementGeometryCount = ->
        geometryCount++
        if geometryCount % 100 == 0 || geometryCount == c3mls.length
          Logger.debug('Parsed ' + geometryCount + '/' + c3mls.length + ' geometries')

      _.each c3mls, (c3ml, i) ->
        c3mlId = c3ml.id
        c3mlMap[c3mlId] = c3ml
        c3mlProps = c3ml.properties ? {}
        modelDf = Q.defer()
        modelDfs.push(modelDf.promise)
        entityDfMap[c3mlId] = modelDf
        geomDf = Q.defer()
        geomDfMap[c3mlId] = geomDf.promise
        geomDf.promise.then -> incrementGeometryCount()

        scheduler.add ->
          type = AtlasConverter.sanitizeType(c3ml.type)
          parentId = c3ml.parentId
          if parentId
            edges.push([parentId, c3mlId])
            sortMap[parentId] = sortMap[c3mlId] = true
          # Create a pseudo-filename so the data is detected as a File rather than serialized JSON
          # or WKT.
          filename = c3mlId + '.json'
          if type == 'mesh'
            c3mlStr = JSON.stringify({c3mls: [c3ml]})
            if c3mlStr.length < GEOMETRY_SIZE_LIMIT
              # If the c3ml is less than 10MB, just store it in the document directly. A document
              # has a 16MB limit.
              geomDf.resolve(geom_3d: c3mlStr, geom_3d_filename: filename)
            else
              Logger.info('Inserting a mesh exceeding file size limits:', c3mlStr.length, 'bytes')
              # Upload a single file at a time to avoid tripping up CollectionFS.
              uploadQueue.add ->
                uploadDf = Q.defer()
                # Store the mesh as a separate file and use the file ID as the geom_3d value.
                c3ml.project = projectId
                file = new FS.File()
                file.attachData(Arrays.arrayBufferFromString(c3mlStr), type: 'application/json')
                Files.upload(file).then(
                  (fileObj) ->
                    fileId = fileObj._id
                    Logger.info('Inserted a mesh exceeding file size limits:', fileId)
                    geomDf.resolve(geom_3d: fileId, geom_3d_filename: filename)
                    uploadDf.resolve(fileObj)
                  (err) ->
                    geomDf.reject(err)
                    uploadDf.reject(err)
                )
                return uploadDf.promise
          else if type == 'collection'
            # Ignore collection since it only contains children c3ml IDs.
            geomDf.resolve(null)
          else
            WKT.fromC3ml(c3ml).then(
              (wkt) ->
                geomArgs = if wkt then {geom_2d: wkt, geom_2d_filename: filename} else null
                geomDf.resolve(geomArgs)
              geomDf.reject
            )
          geomDf.promise

      scheduler.run()

      # Add any entities which are not part of a hierarchy and weren't in the topological sort.
      sortedIds = topsort(edges)
      _.each c3mls, (c3ml) ->
        id = c3ml.id
        unless sortMap[id]
          sortedIds.push(id)

      geometryPromises = Q.all(_.values(geomDfMap))
      geometryPromises.fail(df.reject)
      geometryPromises.then bindMeteor =>
        AtlasConverter.getInstance().then bindMeteor (converter) =>
          Logger.info('Geometries parsed. Creating', sortedIds.length, 'entities...')
          _.each sortedIds, (c3mlId, c3mlIndex) =>
            modelDf = entityDfMap[c3mlId]
            scheduler.add =>
              c3ml = c3mlMap[c3mlId]
              c3mlProps = c3ml.properties
              height = popParam(c3mlProps, HeightParamIds)
              height ?= c3ml.height
              elevation = popParam(c3mlProps, ElevationParamIds)
              elevation ?= c3ml.altitude
              geomDfMap[c3mlId].then bindMeteor (geomArgs) =>
                # Geometry may be empty
                space = null
                if geomArgs
                  space = _.extend geomArgs,
                    height: height
                    elevation: elevation

                typeName = null
                inputs = c3mlProps
                # Prevent WKT from being an input.
                delete inputs.WKT
                typeName = popParam(c3mlProps, TypeParamIds)
                if isIfc
                  ifcType = popParam(c3mlProps, IfcTypeParamIds)
                  if ifcType
                    if typeName then inputs.IfcType = typeName
                    typeName = ifcType

                createEntityArgs = _.extend({
                  c3ml: c3ml
                  c3mlIndex: c3mlIndex
                  entityDfMap: entityDfMap
                  projectId: projectId
                  space: space
                  inputs: inputs
                  converter: converter
                  childrenNameMap: childrenNameMap
                }, args)

                parentId = c3ml.parentId
                if parentId && !entityDfMap[parentId]?
                  missingParentsIdMap[parentId] = true

                createEntity = => @_createEntityFromAsset.call(@, createEntityArgs)
                modelDf.promise.then(incrementC3mlCount)

                if typeName
                  getOrCreateTypologyByName(typeName).then bindMeteor (typeId) ->
                    createEntityArgs.typeId = typeId
                    createEntity()
                else
                  createEntity()

              modelDf.promise
          scheduler.run()

    Q.all(modelDfs).then(
      bindMeteor ->
        requirejs ['atlas/model/GeoPoint'], bindMeteor (GeoPoint) ->
          importCount = modelDfs.length
          resolve = -> df.resolve(importCount)
          Logger.info 'Imported ' + importCount + ' entities'
          missingParentIds = _.keys missingParentsIdMap
          if missingParentIds.length > 0
            Logger.error('Missing parent IDs', missingParentIds)

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
            if assetPosition? && assetPosition.longitude != 0 && assetPosition.latitude != 0
              Logger.debug 'Setting project location', assetPosition
              Projects.setLocationCoords(projectId, assetPosition).then(resolve, df.reject)
            else
              resolve()
      df.reject
    )
    df.promise

  _createEntityFromAsset: (args) ->
    c3ml = args.c3ml
    c3mlIndex = args.c3mlIndex
    entityDfMap = args.entityDfMap
    projectId = args.projectId
    typeId = args.typeId
    space = args.space
    inputs = args.inputs
    colorOverride = args.color
    converter = args.converter
    childrenNameMap = args.childrenNameMap
    
    c3mlId = c3ml.id
    parentId = c3ml.parentId
    childrenNameMap[parentId] ?= {}
    modelDf = entityDfMap[c3mlId]
    c3mlProps = c3ml.properties

    # Wait until the parent is inserted so we can reference its ID. Use Q.when() in case
    # there is no parent.
    Q.when(entityDfMap[parentId]?.promise).then bindMeteor (entityParamId) ->
      # Determine the name by either using the one given or generating a default one.      
      getDefaultName = Typologies.findOne(typeId)?.name ? 'Entity'
      name = c3ml.name ? popParam(c3mlProps, NameParamIds) ? getDefaultName
      # If the name is already taken by at least one other sibling, increment it with a numeric
      # suffix.
      commonNameSiblingIds = childrenNameMap[parentId][name] ?= []
      if commonNameSiblingIds.length > 0
        name = name + ' ' + (commonNameSiblingIds.length + 1)
      commonNameSiblingIds.push(c3mlId)

      # If type is provided, don't use c3ml default color and only use param values if
      # they exist to override the type color.
      fillColor = popParam(c3mlProps, FillColorParamIds) ? (!typeId && c3ml.color)
      if colorOverride then fillColor = colorOverride
      borderColor = popParam(c3mlProps, BorderColorParamIds) ? (!typeId && c3ml.borderColor)
      if fillColor
        fill_color = converter.colorFromC3mlColor(fillColor).toString()
      if borderColor
        border_color = converter.colorFromC3mlColor(borderColor).toString()
      
      model =
        name: name
        project: projectId
        parent: entityParamId
        parameters:
          general:
            type: typeId
          space: space
          style:
            fill_color: fill_color
            border_color: border_color
          inputs: inputs
      callback = (err, insertId) ->
        if err
          Logger.error('Failed to insert entity', err)
          try
            entityStr = JSON.stringify(args)
            if entityStr.length > CONSOLE_LOG_SIZE_LIMIT && Meteor.isServer
              FileLogger.log(entityStr)
            else
              Logger.debug('Failed entity', entityStr)
          catch e
            Logger.error('Failed to log entity insert failure', e)
          modelDf.reject(err)
        else
          modelDf.resolve(insertId)
      Entities.insert model, callback
    modelDf.promise

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
      bindMeteor (geom) ->
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
      renderQueue.add id, => @_render(id, args).then(df.resolve, df.reject)
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
    renderingEnabledDf.promise.then bindMeteor =>
      # renderDfs = []
      # models = Entities.findByProject().fetch()
      @_chooseDisplayMode()
      # _.each models, (model) => renderDfs.push(@render(model._id))
      # df.resolve(Q.all(renderDfs))
      promise = renderQueue.add 'bulk', => @_renderBulk(args)
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
    WKT.getWKT bindMeteor (wkt) =>
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
        bindMeteor (results) ->
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

  whenRenderingComplete: -> renderQueue.waitForAll()

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
      renderQueue.add id, ->
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
    Q.all(unrenderPromises).then bindMeteor =>
      renderPromise = @_renderBulk({ids: ids, projectId: projectId})
      renderPromise.then -> 
        geoEntities = _.map ids, (id) -> AtlasManager.getEntity(id)
        _.each geoEntities, (entity) ->
          addEntity(entity)
          _.each entity.getRecursiveChildren(), addEntity
        _.each entitiesJson, (json) -> json.type = json.type.toUpperCase()
        df.resolve(c3mls: entitiesJson)
      # Unrender all entities when on the server to prevent using old rendered data.
      renderPromise.fin bindMeteor => if Meteor.isServer then _.each ids, (id) => @unrender(id)
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

WKT.getWKT bindMeteor (wkt) ->
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
    'entities/from/asset': (args) -> Promises.runSync -> EntityUtils.fromAsset(args)
    'entities/to/json': (projectId, scenarioId) ->
      Promises.runSync -> EntityUtils.getEntitiesAsJson
        projectId: projectId
        scenarioId: scenarioId
    'entities/to/kmz': (projectId, scenarioId) ->
      EntityUtils.convertToKmz
        projectId: projectId
        scenarioId: scenarioId
