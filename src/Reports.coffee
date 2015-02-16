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
  project: SchemaUtils.projectSchema()

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
