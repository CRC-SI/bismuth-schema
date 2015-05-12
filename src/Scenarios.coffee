ScenarioSchema = new SimpleSchema
  name:
    type: String
    index: true
    unique: false
  desc: SchemaUtils.descSchema()
  project: SchemaUtils.projectSchema()

Scenarios = new Meteor.Collection 'scenarios'
Scenarios.attachSchema(ScenarioSchema)
Scenarios.allow(Collections.allowAll())
Scenarios.findByProject = (projectId) -> SchemaUtils.findByProject(Scenarios, projectId)

if Meteor.isClient
  # No current scenario exists on server.
  Scenarios.after.insert (userId, scenario) ->
    id = scenario._id
    Meteor.call 'scenarios/setup', id, ScenarioUtils.getCurrentId(), (err, result) ->
      ScenarioUtils.setCurrentId(id)
  handle = null
  Tracker.autorun ->
    loadDf = Q.defer()
    Scenarios.ready = -> loadDf.promise
    # Listen to changes in the scenario and re-subscribe to entities.
    scenarioId = ScenarioUtils.getCurrentId()
    projectId = Projects.getCurrentId()
    return unless projectId
    handle?.stop()
    EntityUtils.enableRendering(false)
    handle = Meteor.subscribe 'entities', projectId, scenarioId, ->
      console.log('onReady', @, arguments)
      EntityUtils.enableRendering(true)
      loadDf.resolve()
      PubSub.publish 'scenarios/loaded', scenarioId
