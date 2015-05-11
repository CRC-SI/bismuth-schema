typologyCategories =
  style:
    items:
      fill_color:
        label: 'Colour'
        type: String
      border_color:
        label: 'Border Colour'
        type: String

ParametersSchema = SchemaUtils.createCategoriesSchema
  categories: typologyCategories

TypologySchema = new SimpleSchema
  name:
    type: String
    index: true
  desc: SchemaUtils.descSchema()
  parameters:
    label: 'Parameters'
    type: ParametersSchema
    # Necessary to allow required fields within.
    optional: false
    defaultValue: {}
  project: SchemaUtils.projectSchema()

TypologySchema.ParametersSchema = ParametersSchema
