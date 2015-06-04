####################################################################################################
# AUXILIARY
####################################################################################################

GEOMETRY_SIZE_LIMIT = 1024 * 1024 * 10 # 10MB
CONSOLE_LOG_SIZE_LIMIT = 1024 * 1024 # 1MB

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

uploadQueue = null
resetUploadQueue = -> uploadQueue = new DeferredQueue()

Meteor.startup ->
  resetUploadQueue()

####################################################################################################
# END AUXILIARY
####################################################################################################

EntityImporter =

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
      return Q.reject('Either c3mls or fileId must be provided for importing.')
    c3mlsPromise.fail(df.reject)
    c3mlsPromise.then Meteor.bindEnvironment (c3mls) =>
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
      runner = new TaskRunner()
      insertedCount = 0
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

      getOrCreateTypologyByName = (name) =>
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
          SchemaUtils.setParameterValue(typologyDoc, 'style.fill_color', fillColor)
          typologyDoc = @_mapTypology(typologyDoc) ? typologyDoc
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

      _.each c3mls, (c3ml, i) =>
        c3mlId = c3ml.id
        c3mlMap[c3mlId] = c3ml
        # TODO(aramk) Use the ID given by ACS instead of attempting to name it here.
        modelDf = Q.defer()
        modelDfs.push(modelDf.promise)
        entityDfMap[c3mlId] = modelDf
        geomDf = Q.defer()
        geomDfMap[c3mlId] = geomDf.promise
        parentId = c3ml.parentId
        if parentId
          edges.push([parentId, c3mlId])
          sortMap[c3mlId] = sortMap[parentId] = true
        runner.add => @_geometryFromC3ml(c3ml, geomDf)

      # Add any entities which are not part of a hierarchy and weren't in the topological sort.
      sortedIds = topsort(edges)
      _.each c3mls, (c3ml) ->
        id = c3ml.id
        unless sortMap[id] then sortedIds.push(id)

      runner.run()
      geometryPromises = Q.all(_.values(geomDfMap))
      geometryPromises.fail(df.reject)
      geometryPromises.then Meteor.bindEnvironment =>
        AtlasConverter.getInstance().then Meteor.bindEnvironment (converter) =>
          Logger.info('Geometries parsed. Creating', sortedIds.length, 'entities...')
          _.each sortedIds, (c3mlId, c3mlIndex) =>
            modelDf = entityDfMap[c3mlId]
            runner.add =>
              c3ml = c3mlMap[c3mlId]
              c3mlProps = c3ml.properties
              height = popParam(c3mlProps, HeightParamIds)
              height ?= c3ml.height
              elevation = popParam(c3mlProps, ElevationParamIds)
              elevation ?= c3ml.altitude
              geomDfMap[c3mlId].then Meteor.bindEnvironment (geomArgs) =>

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
                  getOrCreateTypologyByName(typeName).then Meteor.bindEnvironment (typeId) ->
                    createEntityArgs.typeId = typeId
                    createEntity()
                else
                  createEntity()
              
              modelDf.promise

          runner.run()

    modelsPromise = Q.all(modelDfs)
    modelsPromise.fail(df.reject)
    modelsPromise.then Meteor.bindEnvironment ->
      requirejs ['atlas/model/GeoPoint'], Meteor.bindEnvironment (GeoPoint) ->
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
    df.promise

  _geometryFromC3ml: (c3ml, geomDf) ->
    c3mlId = c3ml.id
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
    Q.when(entityDfMap[parentId]?.promise).then Meteor.bindEnvironment (entityParamId) =>
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
        parent: entityParamId
        project: projectId
        parameters:
          general:
            type: typeId
          space: space
          style:
            fill_color: fill_color
            border_color: border_color
          inputs: inputs
      model = @_mapEntity(model) ? model
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

  _mapEntity: (doc) -> doc
  _mapTypology: (doc) -> doc

if Meteor.isServer

  Meteor.methods
    'entities/from/asset': (args) -> Promises.runSync -> EntityImporter.fromAsset(args)
