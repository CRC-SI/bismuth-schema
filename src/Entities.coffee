####################################################################################################
# ENTITY SCHEMA DEFINITION
####################################################################################################

entityCategories =
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
      fpa: SchemaUtils.extendSchema(SchemaUtils.areaSchema(), {
        label: 'Footprint Area'
      })
  style:
    items:
      fill_color:
        label: 'Color'
        type: String
      border_color:
        label: 'Border Color'
        type: String

ParametersSchemaFields = SchemaUtils.createCategoriesSchemaFields
  categories: entityCategories
@ParametersSchema = new SimpleSchema(ParametersSchemaFields)

parametersSchema = Object.freeze
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
  typology:
    label: 'Typology'
    type: String
    collectionType: 'Typologies'
  parameters: parametersSchema
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

Entities = new Meteor.Collection 'entities'
Entities.attachSchema(EntitySchema)
Entities.allow(Collections.allowAll())

Entities.resolveTypeId = (type) -> type.toLowerCase().replace(/\s+/g, '_')

Entities.findByProject = (projectId) -> SchemaUtils.findByProject(Entities, projectId)

Entities.findByProjectAndScenario = (projectId, scenarioId) ->
  # NOTE: Always use Entities.findByProject() for a cursor on all entities as scenarios are
  # switched. Entities.findByProjectAndScenario() should only be used for publishing or when
  # repeated calls are possible. If a single call is made when no scenario exists, the returend
  # cursor won't be updated with entities in scenarios.
  projectId ?= Projects.getCurrentId()
  unless projectId
    throw new Error('Project ID not provided - cannot retrieve models.')
  # Only entities of the current scenario (if any) or the baseline project should be returned.
  if scenarioId
    Entities.find({scenario: scenarioId, project: projectId})
  else
    Entities.find({scenario: {$exists: false}, project: projectId})

Entities.findByTypology = (typologyId) -> Entities.find({typology: typologyId})

Entities.getInputNames = (collection) ->
  entities = Collections.getItems(collection)
  allInputs = {}
  _.each entities, (entity) ->
    _.each entity.parameters.inputs, (value, key) ->
      allInputs[key] = true
  Object.keys(allInputs)

Entities.getChildren = (parentId) -> Entities.find({parent: parentId})

Entities.getFlattened = (id) ->
  entity = Entities.findOne(id)
  Entities.mergeTypology(entity)
  entity

Entities.getAllFlattenedInProject = (filter) ->
  entities = Entities.findByProject().fetch()
  if filter
    entities = _.filter entities, filter
  _.map entities, (entity) -> Entities.getFlattened(entity._id)

Entities.mergeTypology = (entity) ->
  typologyId = entity.typology
  if typologyId?
    typology = Typologies.findOne(typologyId)
    Entities.mergeTypologyObj(entity, typology)
  entity

Entities.mergeTypologyObj = (entity, typology) ->
  if typology?
    entity._typology = typology
    SchemaUtils.mergeDefaultParameterValues(typology, Typologies)
    entity.parameters ?= {}
    Setter.defaults(entity.parameters, typology.parameters)
    Typologies.filterParameters(entity)
  entity
