entityCategories =
  general:
    items:
      type:
        type: String
        index: true
        optional: true
  space:
    items:
      geom_2d:
        label: '2D Geometry'
        type: String
        desc: '2D footprint geometry'
      geom_3d:
        label: '3D Geometry'
        type: String
        desc: '3D mesh representation'
      geom_2d_filename:
        label: '2D Geometry Filename'
        type: String
        desc: 'The name of the file representing the 2D geometry.'
      geom_3d_filename:
        label: '3D Geometry Filename'
        type: String
        desc: 'The name of the file representing the 3D geometry.'
      height: SchemaUtils.heightSchema()
      elevation: SchemaUtils.elevationSchema()
      fpa: SchemaUtils.extendSchema SchemaUtils.areaSchema(),
        label: 'Footprint Area'
  style:
    items:
      fill_color:
        label: 'Colour'
        type: String
      border_color:
        label: 'Border Colour'
        type: String

ParametersSchemaFields = SchemaUtils.createCategoriesSchemaFields
  categories: entityCategories
# Dynamic parameters
_.extend ParametersSchemaFields,
  inputs:
    label: 'Input Parameters'
    desc: 'Input values used in analysis.'
    type: Object
    blackbox: true
    defaultValue: {}
  outputs:
    label: 'Output Parameters'
    desc: 'Output values calculated by analysis services.'
    type: Object
    blackbox: true
    defaultValue: {}
ParametersSchema = new SimpleSchema(ParametersSchemaFields)

parametersSchemaField = Object.freeze
  label: 'Parameters'
  type: ParametersSchema
  # Necessary to allow required fields within.
  optional: false
  defaultValue: {}

EntitySchema = new SimpleSchema
  name:
    type: String
    index: true
  desc: SchemaUtils.descSchema()
  parameters: parametersSchemaField
  parent:
    type: String
    optional: true
    index: true
  scenario:
    label: 'Scenario'
    type: String
    index: true
    optional: true
  # TODO(aramk) Currently using fixed types instead of objects. Eventually we may want to reuse
  # Typlogies from ESP if we expect them to be user-defined.
  project: SchemaUtils.projectSchema()

EntitySchema.ParametersSchema = ParametersSchema
EntitySchema.parametersSchemaField = parametersSchemaField
