Meteor.methods

  'projects/remove': (id) ->
    AccountsUtil.authorize(Projects.findOne(id), @userId)
    Projects.remove(id)
    # Collections can only be removed by ID on the client, hence we need this method.
    selector = {project: id}
    Entities.remove(selector)
    files = Files.find(selector).fetch()
    console.log('Removing files', files)
    Files.remove(selector)

  'projects/duplicate': (id) ->
    AccountsUtil.authorize(Projects.findOne(id), @userId)
    Promises.runSync ->
      ProjectUtils.duplicate(id).then (idMaps) ->
        idMaps[Collections.getName(Projects)][id]
