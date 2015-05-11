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
      allowedValues: [
        'Australian Capital Territory'
        'New South Wales'
        'Northern Territory'
        'South Australia'
        'Tasmania'
        'Queensland'
        'Victoria'
        'West Australia'
        'New Zealand'
      ]
    loc_auth:
      label: 'LGA or Suburb'
      type: String
      desc: 'Local government authority or suburb in which this precinct resides.'
      optional: false
    suburb:
      label: 'Suburb'
      type: String
      desc: 'Suburb in which this precinct resides.'
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
    
ParametersSchema = SchemaUtils.createCategoriesSchema
  categories: projectCategories

ProjectSchema = new SimpleSchema
  name:
    type: String
    index: true
    unique: false
  desc: SchemaUtils.descSchema()
  author:
    type: String
    index: true
  parameters:
    label: 'Parameters'
    type: ParametersSchema
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
Projects.ParametersSchema = ParametersSchema
Projects.allow(Collections.allowAll())
AccountsUtil.addCollectionAuthorization(Projects)

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

##################################################################################################
# PROJECT DATE
##################################################################################################

# Updating project or models in the project will update the modified date of a project.

getCurrentDate = -> moment().toDate()

Projects.before.insert (userId, doc) ->
  unless doc.dateModified
    doc.dateModified = getCurrentDate()

Projects.before.update (userId, doc, fieldNames, modifier) ->
  modifier.$set ?= {}
  delete modifier.$unset?.dateModified
  modifier.$set.dateModified = getCurrentDate()

# TODO(aramk) Allow defining a set of collections before we can use this.
# _.each [Entities, Typologies, Layers, Scenarios, Reports], (collection) ->
#   _.each ['insert', 'update'], (operation) ->
#     collection.after[operation] (userId, doc) ->
#       projectId = doc.project
#       Projects.update(projectId, {$set: {dateModified: getCurrentDate()}})

# return Projects
