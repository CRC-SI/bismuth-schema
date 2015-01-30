####################################################################################################
# SCHEMA OPTIONS
####################################################################################################

SimpleSchema.debug = true
SimpleSchema.extendOptions
# Optional extra fields.
  desc: Match.Optional(String)
  units: Match.Optional(String)
# Used on reference fields containing IDs of models in the given collection type.
  collectionType: Match.Optional(String)
# An expression for calculating the value of the given field for the given model. These are output
# fields and do not appear in forms. The formula can be a string containing other field IDs prefixed
# with '$' (e.g. $occupants) which are resolved to the local value per model, or global parameters
# if no local equivalent is found. If the expression is a function, it is passed the current model
# and the field and should return the result.
  calc: Match.Optional(Match.Any)
# A map of class names to objects of properties. "defaultValues" specifies the default value for
# the given class.
  classes: Match.Optional(Object)

####################################################################################################
# COMMON SCHEMA AUXILIARY
####################################################################################################

# ^ and _ are converted to superscript and subscript in forms and reports.
@Units =
  $m2: '$/m^2'
  $: '$'
  $day: '$/day'
  $kWh: '$/kWh'
  $MJ: '$/MJ'
  $kL: '$/kL'
  co2: 'kg CO_2-e'
  co2kWh: 'kg CO_2-e/kWh'
  co2m2year: 'kg CO_2-e/m^2/year'
  co2year: 'kg CO_2-e/year'
  co2GJ: 'kg CO_2-e/GJ'
  deg: 'degrees'
  GJ: 'GJ'
  GJm2: 'GJ/m2'
  GJm2year: 'GJ/m2/year'
  GJyear: 'GJ/year'
  GJyearOccupant: 'GJ/year/occupant'
  ha: 'ha'
  jobs: 'jobs'
  kgco2: 'kg CO_2-e'
  kgco2day: 'kg CO_2-e/day'
  kgco2kWh: 'kg CO_2-e/kWh'
  kgco2km: 'kg CO_2-e/km'
  kgco2m2: 'kg CO_2-e/m^2'
  kgco2year: 'kg CO_2-e/year'
  kW: 'kW'
  kWh: 'kWh'
  kWhday: 'kWh/day'
  kWhyear: 'kWh/year'
  kLyear: 'kL/year'
  kLyearOccupant: 'kL/year/occupant'
  kLm2year: 'kL/m^2/year'
  km: 'km'
  kmday: 'km/day'
  kmyear: 'km/year'
  lanes: 'lanes'
  Lsec: 'L/second'
  Lyear: 'L/year'
  m: 'm'
  m2: 'm^2'
  m2vehicle: 'm^2/vehicle'
  m2job: 'm^2/job'
  mm: 'mm'
  MLyear: 'ML/year'
  MJ: 'MJ'
  MJm2year: 'MJ/m^2/year'
  MJyear: 'MJ/year'
  people: 'people'
  spaces: 'spaces'
  spacesm: 'spaces/m'
  tripsday: 'trips/day'
  tripsyear: 'trips/year'
  vehicles: 'vehicles'
  years: 'years'

extendSchema = (orig, changes) -> _.extend({}, orig, changes)

# TODO(aramk) Can't use Strings or other utilities outside Meteor.startup since it's not loaded yet
toTitleCase = (str) ->
  parts = str.split(/\s+/)
  title = ''
  for part, i in parts
    if part != ''
      title += part.slice(0, 1).toUpperCase() + part.slice(1, part.length)
      if i != parts.length - 1 and parts[i + 1] != ''
        title += ' '
  title

autoLabel = (field, id) ->
  label = field.label
  if label?
    label
  else
    label = id.replace('_', '')
    toTitleCase(label)

createCategorySchemaObj = (cat, catId, args) ->
  catSchemaFields = {}
  hasRequiredField = false
  _.each cat.items, (item, itemId) ->
    if item.items?
      result = createCategorySchemaObj(item, itemId, args)
      if result.hasRequiredField
        hasRequiredField = true
      fieldSchema = result.schema
    else
      # Required fields must explicitly specify "optional" as false.
      fieldSchema = _.extend({optional: true}, args.itemDefaults, item)
      if fieldSchema.optional == false
        hasRequiredField = true
      autoLabel(fieldSchema, itemId)
      # If defaultValue is used, put it into "classes" to prevent SimpleSchema from storing this
      # value in the doc. We want to inherit this value at runtime for all classes, but not
      # persist it in multiple documents in case we want to change it later in the schema.
      defaultValue = fieldSchema.defaultValue
      if defaultValue?
        classes = fieldSchema.classes ?= {}
        # console.log('itemId', itemId)
        # console.log('allClassOptions', allClassOptions)
        # console.log('classes', classes)
        allClassOptions = classes.ALL ?= {}
        # TODO(aramk) This block causes a strange issue where ALL.classes is defined with
        # defaultValue already set, though it wasn't a step earlier...
        if allClassOptions.defaultValue?
          # console.log('fieldSchema', fieldSchema)
          # console.log('classes', classes)
          # console.log('BuildingClasses', BuildingClasses)
          # console.log('extend', extendBuildingClasses())
          throw new Error('Default value specified on field ' + itemId + ' and in classOptions - only use one.')
        # console.log('setting defualt value', allClassOptions)
        allClassOptions.defaultValue = defaultValue
        delete fieldSchema.defaultValue
    catSchemaFields[itemId] = fieldSchema
  catSchema = new SimpleSchema(catSchemaFields)
  catSchemaArgs = _.extend({
    # If a single field is required, the entire category is marked required. If no fields are
    # required, the category can be omitted.
    optional: !hasRequiredField
  }, args.categoryDefaults, cat, {type: catSchema})
  autoLabel(catSchemaArgs, catId)
  delete catSchemaArgs.items
  {hasRequiredField: hasRequiredField, schema: catSchemaArgs}

# Constructs SimpleSchema fields which contains all categories and each category is it's own
# SimpleSchema.
createCategoriesSchemaFields = (args) ->
  args ?= {}
  cats = args.categories
  unless cats
    throw new Error('No categories provided.')
  # For each category in the schema.
  catsFields = {}
  for catId, cat of cats
    catSchemaArgs = createCategorySchemaObj(cat, catId, args)
    catsFields[catId] = catSchemaArgs
  catsFields

createCategoriesSchema = (args) -> new SimpleSchema(createCategoriesSchemaFields(args))

forEachCategoryField = (category, callback) ->
  for itemId, item of category.items
    if item.items?
      forEachCategoryField(item, callback)
    else
      callback(itemId, item, category)

forEachCategoriesField = (categories, callback) ->
  for catId, category of categories
    forEachCategoryField(category, callback)

mergeObjectsWithTemplate = (args) ->
  template = args.template
  result = {}
  _.map args.items, (item, itemId) ->
    result[itemId] = Setter.merge(Setter.clone(template), item)
  result

mergeDefaultsWithTemplate = (args) ->
  items = args.items
  _.each items, (value, key) ->
    items[key] = {defaultValue: value}
  mergeObjectsWithTemplate(args)

####################################################################################################
# COMMON SCHEMA DEFINITION
####################################################################################################

descSchema =
  label: 'Description'
  type: String

projectSchema =
  label: 'Project'
  type: String
  index: true
  collectionType: 'Projects'

heightSchema =
  type: Number
  decimal: true
  desc: 'Maximum height of the entity (excluding elevation).'
  units: Units.m

elevationSchema =
  type: Number
  decimal: true
  desc: 'Elevation from ground-level to the base of this entity.'
  units: Units.m

calcArea = (id) ->
  feature = AtlasManager.getEntity(id)
  if feature
    target = feature.getForm('footprint')
    unless target
      target = feature.getForm('mesh')
    unless target
      throw new Error('GeoEntity was found but no footprint or mesh exists - cannot calculate ' +
        'area.')
    target.getArea()
  else
    throw new Error('GeoEntity not found - cannot calculate area.')

calcLength = (id) ->
  feature = AtlasManager.getEntity(id)
  line = feature.getForm('line')
  unless line
    throw new Error('Cannot calculate length of non-line GeoEntity with ID ' + id)
  line.getLength()

areaSchema =
  label: 'Area'
  type: Number
  desc: 'Area of the land parcel.'
  decimal: true
  units: Units.m2
  calc: -> calcArea(@model._id)

####################################################################################################
# PROJECT SCHEMA DEFINITION
####################################################################################################

projectCategories =
  location:
    label: 'Location'
    items:
      country:
        type: String
        desc: 'Country of precinct: either Australia or New Zealand.'
        allowedValues: ['Australia', 'New Zealand']
        optional: false
      ste_reg:
        label: 'State, Territory or Region'
        type: String
        desc: 'State, territory or region in which the precinct is situated.'
        optional: false
      loc_auth:
        label: 'Local Government Authority'
        type: String
        desc: 'Local government authority in which this precinct predominantly or completely resides.'
        optional: false
      suburb:
        label: 'Suburb'
        type: String
        desc: 'Suburb in which this precinct predominantly or completely resides.'
      post_code:
        label: 'Post Code'
        type: Number
        desc: 'Post code in which this precinct predominantly or completely resides.'
      sa1_code:
        label: 'SA1 Code'
        type: Number
        desc: 'SA1 in which this precinct predominantly or completely resides.'
      lat:
        label: 'Latitude'
        type: Number
        decimal: true
        units: Units.deg
        desc: 'The latitude coordinate for this precinct'
      lng:
        label: 'Longitude'
        type: Number
        decimal: true
        units: Units.deg
        desc: 'The longitude coordinate for this precinct'
      cam_elev:
        label: 'Camera Elevation'
        type: Number
        decimal: true
        units: Units.m
        desc: 'The starting elevation of the camera when viewing the project.'
      
@ProjectParametersSchema = createCategoriesSchema
  categories: projectCategories

ProjectSchema = new SimpleSchema
  name:
    type: String
    index: true
    unique: false
  desc: descSchema
  author:
    type: String
    index: true
  parameters:
    label: 'Parameters'
    type: ProjectParametersSchema
    defaultValue: {}
  dateModified:
    label: 'Date Modified'
    type: Date
  isTemplate:
    label: 'Template?'
    type: Boolean
    defaultValue: false

Projects = new Meteor.Collection 'projects'
Projects.attachSchema(ProjectSchema)
Projects.allow(Collections.allowAll())
AccountsAurin.addCollectionAuthorization Projects,
  # A user has access to their own projects as well as any templates.
  userSelector: (args) -> {$or: [{author: args.username}, {isTemplate: true}]}

if Meteor.isClient
  reactiveProject = new ReactiveVar(null)
  Projects.setCurrentId = (id) -> reactiveProject.set(id)
  Projects.getCurrent = -> Projects.findOne(Projects.getCurrentId())
  Projects.getCurrentId = -> reactiveProject.get('projectId')

Projects.getLocationAddress = (id) ->
  project = Projects.findOne(id)
  location = project.parameters.location
  components = [location.suburb, location.loc_auth, location.ste_reg, location.country]
  (_.filter components, (c) -> c?).join(', ')

Projects.getLocationCoords = (id) ->
  project = if id then Projects.findOne(id) else Projects.getCurrent()
  location = project.parameters.location
  {latitude: location.lat, longitude: location.lng, elevation: location.cam_elev}

Projects.setLocationCoords = (id, location) ->
  df = Q.defer()
  id ?= Projects.getCurrentId()
  Projects.update id, $set: {
    'parameters.location.lat': location.latitude
    'parameters.location.lng': location.longitude
  }, (err, result) -> if err then df.reject(err) else df.resolve(result)
  df.promise

# Template Projects

Projects.before.insert = (userId, doc) ->
  if doc.isTemplate && !AuthUtils.isAdmin(userId)
    throw new Error('Only admin user can create template project.')

####################################################################################################
# TYPOLOGY SCHEMA DEFINITION
####################################################################################################

typologyCategories =
  style:
    items:
      fill_color:
        label: 'Color'
        type: String
      border_color:
        label: 'Border Color'
        type: String

@TypologiesParametersSchema = createCategoriesSchema
  categories: typologyCategories

TypologySchema = new SimpleSchema
  name:
    type: String
    index: true
  desc: descSchema
  parameters:
    label: 'Parameters'
    type: TypologiesParametersSchema
    # Necessary to allow required fields within.
    optional: false
    defaultValue: {}
  project: projectSchema

Typologies = new Meteor.Collection 'typologies'
Typologies.attachSchema(TypologySchema)
Typologies.allow(Collections.allowAll())
Typologies.findByProject = (projectId) -> SchemaUtils.findByProject(Typologies, projectId)
Typologies.findByName = (name, projectId) ->
  projectId = projectId ? Projects.getCurrentId()
  Typologies.findOne({name: name, project: projectId})

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
      height: heightSchema
      elevation: elevationSchema
      fpa: extendSchema(areaSchema, {
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

ParametersSchemaFields = createCategoriesSchemaFields
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
  desc: descSchema
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
  project: projectSchema

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

####################################################################################################
# LAYERS
####################################################################################################

LayerSchema = new SimpleSchema
  name:
    type: String
    index: true
    unique: false
  desc: descSchema
  parameters: parametersSchema
  project: projectSchema

Layers = new Meteor.Collection 'layers'
Layers.attachSchema(LayerSchema)
Layers.allow(Collections.allowAll())
Layers.findByProject = (projectId) -> SchemaUtils.findByProject(Layers, projectId)

####################################################################################################
# SCENARIOS
####################################################################################################

ScenarioSchema = new SimpleSchema
  name:
    type: String
    index: true
    unique: false
  desc: descSchema
  project: projectSchema

Scenarios = new Meteor.Collection 'scenarios'
Scenarios.attachSchema(ScenarioSchema)
Scenarios.allow(Collections.allowAll())
Scenarios.findByProject = (projectId) -> SchemaUtils.findByProject(Scenarios, projectId)

####################################################################################################
# REPORTS
####################################################################################################

ReportSchema = new SimpleSchema
  name:
    type: String
    index: true
    unique: false
  type:
    type: String
    optional: true
  fields:
    type: [Object]
    defaultValue: []
    blackbox: true
  options:
    type: Object
    defaultValue: {}
    blackbox: true
  project: projectSchema

Reports = new Meteor.Collection 'reports'
Reports.attachSchema(ReportSchema)
Reports.allow(Collections.allowAll())
Reports.findByProject = (projectId) -> SchemaUtils.findByProject(Reports, projectId)
Reports.docToInstance = (docOrId) ->
  if Types.isString(docOrId)
    doc = Reports.findOne(docOrId)
    unless doc
      throw new Error('No report found for ID ' + docOrId)
  else
    doc = docOrId
  unless doc
    throw new Error('No report provided')
  doc = Setter.clone(doc)
  doc.id = doc._id
  delete doc._id
  type = doc.type ? 'Report'
  typeClass = window[type]
  new typeClass(doc)

if Meteor.isClient
  # Used to restore the last report opened per project.
  reportsLastOpenedSessionVarName = 'reportsLastOpened'
  Session.setDefaultPersistent(reportsLastOpenedSessionVarName, {})
  Reports.getLastOpened = (projectId) ->
    projectId ?= Projects.getCurrentId()
    Session.get(reportsLastOpenedSessionVarName)[projectId]
  Reports.setLastOpened = (reportId, projectId) ->
    projectId ?= Projects.getCurrentId()
    map = Session.get(reportsLastOpenedSessionVarName)
    map[projectId] = reportId
    Session.setPersistent(reportsLastOpenedSessionVarName, map)
  Reports.removeLastOpened = (projectId) ->
    projectId ?= Projects.getCurrentId()
    map = Session.get(reportsLastOpenedSessionVarName)
    delete map[projectId]
    Session.setPersistent(reportsLastOpenedSessionVarName, map)

# Listen for changes to Entities or Typologies and refresh reports.
_reportRefreshSubscribed = false
subscribeRefreshReports = ->
  return if _reportRefreshSubscribed
  _.each [
    {collection: Entities, observe: ['added', 'changed', 'removed']}
    {collection: Typologies, observe: ['changed']}
  ], (args) ->
    collection = args.collection
    shouldRefresh = false
    refreshReport = ->
      if shouldRefresh
        # TODO(aramk) Report refreshes too soon and geo entity is being reconstructed after an
        # update. This delay is a quick fix, but we should use promises.
        setTimeout (-> PubSub.publish('report/refresh')), 1000
    cursor = collection.find()
    _.each _.unique(args.observe), (methodName) ->
      observeArgs = {}
      observeArgs[methodName] = refreshReport
      cursor.observe(observeArgs)
    # TODO(aramk) Temporary solution to prevent refreshing due to added callback firing for all
    # existing docs.
    shouldRefresh = true
    _reportRefreshSubscribed = true
# Refresh only if a report has been rendered before.
PubSub.subscribe 'report/rendered', subscribeRefreshReports

####################################################################################################
# ASSOCIATION MAINTENANCE
####################################################################################################

Typologies.after.remove (userId, typology) ->
  # Remove entities when the typology is removed.
  _.each Entities.findByTypology(typology._id).fetch(), (entity) -> Entities.remove(entity._id)

####################################################################################################
# PROJECT DATE
####################################################################################################

# Updating project or models in the project will update the modified date of a project.

getCurrentDate = -> moment().toDate()

Projects.before.insert (userId, doc) ->
  unless doc.dateModified
    doc.dateModified = getCurrentDate()

Projects.before.update (userId, doc, fieldNames, modifier) ->
  modifier.$set ?= {}
  delete modifier.$unset?.dateModified
  modifier.$set.dateModified = getCurrentDate()

_.each [Entities, Typologies, Layers, Scenarios, Reports], (collection) ->
  _.each ['insert', 'update'], (operation) ->
    collection.after[operation] (userId, doc) ->
      projectId = doc.project
      Projects.update(projectId, {$set: {dateModified: getCurrentDate()}})

####################################################################################################
# TYPOLOGY COLORS
####################################################################################################

TypologyColors = ['#8dd3c7', '#ffffb3', '#bebada', '#fb8072', '#80b1d3', '#fdb462', '#b3de69',
    '#fccde5', '#d9d9d9', '#bc80bd', '#ccebc5', '#a6cee3', '#1f78b4', '#b2df8a', '#33a02c',
    '#fb9a99', '#e31a1c', '#fdbf6f', '#ff7f00', '#cab2d6', '#6a3d9a', '#ffff99']

Typologies.getNextAvailableColor = (projectId, options) ->
  options = _.extend({
    exclude: []
  }, options)
  typologyColorMap = {}
  Typologies.findByProject(projectId).forEach (typology) ->
    color = SchemaUtils.getParameterValue(typology, 'style.fill_color')
    if color
      typologyColorMap[color] = typology._id
  usedColors = Object.keys(typologyColorMap)
  availableColors = _.difference(TypologyColors, usedColors, options.exclude)
  unless availableColors.length == 0
    availableColors[0]
  else
    Colors.getRandomColor()
