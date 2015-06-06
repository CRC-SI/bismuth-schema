bindMeteor = Meteor.bindEnvironment.bind(Meteor)

renderCount = new ReactiveVar(0)
incrementRenderCount = -> renderCount.set(renderCount.get() + 1)
decrementRenderCount = -> renderCount.set(renderCount.get() - 1)

LayerUtils =

  _renderers: {}

  fromC3mls: (c3mls, args) ->
    args = Setter.merge({}, args)
    df = Q.defer()
    projectId = args.projectId ? Projects.getCurrentId()
    
    # Store in a file to prevent loading unless necessary.
    doc = {c3mls: c3mls, project: projectId}
    # if args.projections
    #   doc.projections = args.projections
    # if args.popups
    #   doc.popups = args.popups

    docString = JSON.stringify(doc)
    file = new FS.File()
    file.attachData(Arrays.arrayBufferFromString(docString), type: 'application/json')
    Files.upload(file).then bindMeteor (fileObj) ->
      # TODO(aramk) For now, using any random ID.
      name = args.name
      model =
        name: name
        type: args.type
        project: projectId
        parameters:
          space:
            geom_3d: fileObj._id
      Layers.insert model, (err, insertId) ->
        if err
          Logger.error('Failed to insert layer', err)
          df.reject(err)
        else
          Logger.info('Inserted layer comprised of ' + c3mls.length + ' c3mls')
          df.resolve(insertId)
    df.promise

  fromData: (data, args) ->
    args = Setter.merge({}, args)
    df = Q.defer()
    projectId = args.projectId ? Projects.getCurrentId()
    
    # Store in a file to prevent loading unless necessary.
    docString = JSON.stringify(data)
    file = new FS.File()
    file.attachData(Arrays.arrayBufferFromString(docString), type: 'application/json')
    Files.upload(file).then bindMeteor (fileObj) ->
      # TODO(aramk) For now, using any random ID.
      name = args.name
      model =
        name: name
        type: args.type
        project: projectId
        parameters:
          space:
            geom_3d: fileObj._id
      Layers.insert model, (err, insertId) ->
        if err
          Logger.error('Failed to insert layer', err)
          df.reject(err)
        else
          Logger.info('Inserted layer with data')
          df.resolve(insertId)
    df.promise

  render: (id) ->
    df = Q.defer()
    incrementRenderCount()
    df.promise.fin -> decrementRenderCount()
    model = Layers.findOne(id)
    space = model.parameters.space
    geom_2d = space.geom_2d
    geom_3d = space.geom_3d
    unless geom_2d || geom_3d
      df.resolve(null)
      decrementRenderCount()
      return df.promise
    geoEntity = AtlasManager.getEntity(id)
    if geoEntity
      @show(id)
      df.resolve(geoEntity)
    else
      @_renderLayer(id).then(
        (geoEntity) =>
          PubSub.publish('layer/show', id)
          df.resolve(geoEntity)
        df.reject
      )
    df.promise

  _renderLayer: (id) ->
    df = Q.defer()
    @_getGeometry(id).then (data) =>
      unless data
        df.resolve(null)
        return
      layer = Layers.findOne(id)
      # Delegate rendering to external modules.
      if layer.type == 'VizUrban'
        renderer = new VizUrbanRenderer(data)
        @_renderers[id] = renderer
        Q.when(renderer.render()).then(
          (entityIds) => df.resolve(@_createCollection(id, entityIds))
          df.reject
        )
        df.resolve()
        return

      # renderEntities() needed to parse c3ml.
      c3mls = data.c3mls
      unless c3mls
        c3mls = [data]
      # Ignore all collections in the c3ml, since they don't affect visualisation of the layer.
      c3mls = _.filter c3mls, (c3ml) -> AtlasConverter.sanitizeType(c3ml.type) != 'collection'
      if c3mls.length == 1
        # Ensure the ID of the layer is assigned if only a single entity rendered.
        c3mls[0].id = id
      AtlasManager.renderEntities(c3mls).then (c3mlEntities) =>
        _.each c3mls, (c3ml) => @_setUpPopup(c3ml)
        if c3mlEntities.length > 1
          entityIds = _.map c3mlEntities, (entity) -> entity.getId()
          df.resolve(@_createCollection(id, entityIds))
        else
          df.resolve(c3mlEntities[0])
    df.promise

  _setUpPopup: (c3ml) ->
    id = c3ml.id
    geoEntity = AtlasManager.getEntity(id)
    properties = c3ml.properties
    description = properties.description
    return unless description

    AtlasManager.getAtlas().then (atlas) ->
      atlas.publish 'popup/onSelection',
        entity: geoEntity
        content: -> description
        title: -> ''

  _createCollection: (id, entityIds) ->
    AtlasManager.createCollection id,
      entities: entityIds
      # Allows children to be selectable, but doesn't bubble up to the collection and select all
      # children, which can cause popups to show for all children.
      selectable: false

  show: (id) ->
    @_renderers[id]?.show?()
    if AtlasManager.showEntity(id)
      PubSub.publish('layer/show', id)

  hide: (id) ->
    return unless AtlasManager.getEntity(id)
    @_renderers[id]?.hide?()
    if AtlasManager.hideEntity(id)
      PubSub.publish('layer/hide', id)

  _getGeometry: (id) ->
    entity = Layers.findOne(id)
    meshFileId = SchemaUtils.getParameterValue(entity, 'space.geom_3d')
    if meshFileId
      Files.downloadJson(meshFileId)
    else
      meshDf = Q.defer()
      meshDf.resolve(null)
      meshDf.promise

  renderAll: ->
    renderDfs = []
    models = Layers.findByProject().fetch()
    _.each models, (model) => renderDfs.push(@render(model._id))
    Q.all(renderDfs)

  getSelectedIds: ->
    # Use the selected entities, or all entities in the project.
    entityIds = AtlasManager.getSelectedFeatureIds()
    # Filter GeoEntity objects which are not project entities.
    _.filter entityIds, (id) -> Layers.findOne(id)

  beforeAtlasUnload: ->
    @resetRenderCount()

  getRenderCount: -> renderCount.get()

  resetRenderCount: -> renderCount.set(0)

