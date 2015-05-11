# Constructs a map of collection name to collection.

reNumberAfterName = /(\d+)(\s*)$/
incrementName = (name) ->
  if reNumberAfterName.test(name)
    name.replace reNumberAfterName, (match, m1, m2) -> (parseInt(m1) + 1) + m2
  else
    name + ' 2'

@ProjectUtils =

# @param {String} id - The ID of the project to serialize.
# @returns {Object} JSON serialization of the given project and its models. IDs are unaltered.
  toJson: (id) ->
    project = Projects.findOne(id)
    unless project
      throw new Error('Project with ID ' + id + ' not found')
    result = {}
    result[Collections.getName(Projects)] = [project]
    collections = _.without(CollectionUtils.getAll(), Projects)
    _.each Collections.getMap(collections), (collection, name) ->
      result[name] = collection.findByProject(id).fetch()
    result

# Constructs new models from the given JSON serialization. IDs are used to retain references between
# the new models and new IDs are generated to replace those in the given JSON.
# @param {Object} json - The serialized JSON. This object may be modified by this method - pass a
# clone if this is undesirable.
# @param {Object} args
# TODO(aramk) Add support for this or remove the option.
# @param {Boolean} args.update - If true, no new models will be constructed. Instead, any existing
# models matching with matching IDs will be updated with the values in the given JSON.
# @returns {Object.<String, Object>} A map of collection names to maps of old IDs to new IDs for the
# models in that collection.
  fromJson: (json, args) ->
    # Construct all models as new documents in the first pass, mapping old ID references to new IDs.
    # In the second pass, change all IDs to the new ones to maintain references in the new models.

    df = Q.defer()
    # A map of collection names to maps of model IDs from the input to the new IDs constructed.
    idMaps = {}

    # Increment the name of Projects to ensure they are unique.
    _.each json[Collections.getName(Projects)], (project) =>
      project.name = @getNextAvailableName(project.name)

    createDfs = []
    collectionMap = Collections.getMap(CollectionUtils.getAll())
    _.each collectionMap, (collection, name) ->
      idMap = idMaps[name] = {}
      _.each json[name], (model) ->
        createDf = Q.defer()
        createDfs.push(createDf.promise)
        oldModelId = model._id
        delete model._id
        # TODO(aramk) Disabling validation is dangerous - only done here to avoid validation
        # errors which don't have messages at the moment. Improve collection2 to provide the
        # message returned from the validate method.
        collection.insert model, {validate: false}, (err, result) ->
          if err
            createDf.reject(err)
          else
            newModelId = result
            idMap[oldModelId] = newModelId
            createDf.resolve(newModelId)
    refDfs = []
    Q.all(createDfs).then(Meteor.bindEnvironment(
      ->
        _.each idMaps, (idMap, name) ->
          collection = collectionMap[name]
          _.each idMap, (newId, oldId) ->
            newModel = collection.findOne(newId)
            modifier = SchemaUtils.getRefModifier(newModel, collection, idMaps)
            if Object.keys(modifier.$set).length > 0
              refDf = Q.defer()
              refDfs.push(refDf.promise)
              collection.update newId, modifier, {validate: false}, (err, result) ->
                if err
                  refDf.reject(err)
                else
                  refDf.resolve(newId)
        Q.all(refDfs).then(
          -> df.resolve(idMaps)
          # TODO(aramk) Remove added models on failure.
          (err) -> df.reject(err)
        )
      )
      (err) -> df.reject(err)
    )
    df.promise

# @params {String} name
# @returns {String} The next available name base on the given name with an incremented numerical
# suffix.
  getNextAvailableName: (name) ->
    newName = name
    while Projects.find({name: newName}).count() != 0
      newName = incrementName(newName)
    newName

# @param {String} id - The ID of the project to duplicate.
# @returns {Object.<String, Object>} A map of collection names to maps of old IDs to new IDs for the
# models in that collection.
  duplicate: (id) ->
    json = @toJson(id)
    @fromJson(json)

  downloadInBrowser: (id) ->
    console.log 'Exporting project', id
    json = @toJson(id)
    blob = Blobs.fromString(JSON.stringify(json), {type: 'application/json'})
    Blobs.downloadInBrowser(blob, 'project-' + id + '.json')

  zoomTo: ->
    projectId = Projects.getCurrentId()
    location = Projects.getLocationCoords(projectId)
    return unless location
    if location.latitude? and location.longitude?
      location.elevation ?= 5000
      console.debug 'Loading project location', location
      AtlasManager.zoomTo
        position: location
        # Aim the camera at the ground.
        orientation:
          rotation: 0
          tilt: -90
          bearing: 0
    else
      address = Projects.getLocationAddress(projectId)
      console.debug 'Loading project address', address
      AtlasManager.zoomTo {address: address}

  getDatedIdentifier: (id) ->
    id ?= Projects.getCurrentId()
    'project-' + id + Dates.toIdentifier(moment())
