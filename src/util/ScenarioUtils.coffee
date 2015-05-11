ScenarioUtils =

  # Duplicates all the docs from the given scenario ID from the current scenario ID.
  setup: (id, currentId) ->
    scenario = Scenarios.findOne(id)
    projectId = scenario.project
    unless scenario
      throw new Error('No scenario found with ID ' + id)
    if Meteor.isClient
      currentId ?= @getCurrentId()
    # Clone all entities and add a reference to the scenario.
    existingEntities = Entities.findByProjectAndScenario(projectId, currentId).fetch()
    Q.all _.map existingEntities, (entity) ->
      entity.scenario = id
      Collections.duplicateDoc(entity, Entities)

if Meteor.isClient

  _.extend ScenarioUtils,

    _currentId: new ReactiveVar(null)

    getCurrentId: -> @_currentId.get()

    setCurrentId: (id) -> @_currentId.set(id)

  Meteor.startup ->
      
    # Revert to the baseline scenario if the current one is removed.
    Collections.observe Scenarios,
      removed: (doc) ->
        currentId = ScenarioUtils.getCurrentId()
        if doc._id == currentId
          ScenarioUtils.setCurrentId(null)
