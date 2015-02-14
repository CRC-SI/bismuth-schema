Depends.define 'TypologySchema', ['SchemaUtils'], (SchemaUtils) ->

  typologyCategories =
    style:
      items:
        fill_color:
          label: 'Color'
          type: String
        border_color:
          label: 'Border Color'
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
  return TypologySchema
