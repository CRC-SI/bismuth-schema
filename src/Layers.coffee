Depends.define 'Layers', ['SchemaUtils', 'EntitySchema'], (SchemaUtils, EntitySchema) ->

  LayerSchema = new SimpleSchema
    name:
      type: String
      index: true
      unique: false
    desc: SchemaUtils.descSchema()
    parameters: EntitySchema.parametersSchemaField
    project: SchemaUtils.projectSchema()

  Collections.ready ->
    Layers = new Meteor.Collection 'layers'
    Layers.attachSchema(LayerSchema)
    Layers.allow(Collections.allowAll())
    Layers.findByProject = (projectId) -> SchemaUtils.findByProject(Layers, projectId)
    return Layers
