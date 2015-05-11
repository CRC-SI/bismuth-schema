LayerSchema = new SimpleSchema
  name:
    type: String
    index: true
    unique: false
  type:
    type: String
    optional: true
  desc: SchemaUtils.descSchema()
  parameters: EntitySchema.parametersSchemaField
project: SchemaUtils.projectSchema()

Layers = new Meteor.Collection 'layers'
Layers.attachSchema(LayerSchema)
Layers.allow(Collections.allowAll())
Layers.findByProject = (projectId) -> SchemaUtils.findByProject(Layers, projectId)
