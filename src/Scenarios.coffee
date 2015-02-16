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
