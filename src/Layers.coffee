####################################################################################################
# LAYERS
####################################################################################################

LayerSchema = new SimpleSchema
  name:
    type: String
    index: true
    unique: false
  desc: SchemaUtils.descSchema()
  parameters: parametersSchema
  project: SchemaUtils.projectSchema()

Layers = new Meteor.Collection 'layers'
Layers.attachSchema(LayerSchema)
Layers.allow(Collections.allowAll())
Layers.findByProject = (projectId) -> SchemaUtils.findByProject(Layers, projectId)
