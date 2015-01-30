Package.describe({
  name: 'urbanetic:bismuth-schema',
  summary: 'Schemas and collections for working with GIS apps.',
  git: 'https://github.com/urbanetic/bismuth-schema.git',
  version: '0.0.1'
});

Package.on_use(function(api) {
  api.versionsFrom('METEOR@0.9.0');
  api.use([
    'coffeescript',
    'underscore',
    'aramk:utility@0.5.2',
    'aramk:q@1.0.1_1',
    'matb33:collection-hooks@0.7.6',
    'aldeed:collection2@2.3.1',
    'aldeed:simple-schema@1.1.0'
  ], ['client', 'server']);
  api.addFiles([
    'src/collections.coffee',
    'src/ParamUtils.coffee',
    'src/SchemaUtils.coffee'
  ], ['client', 'server']);
  api.export([
    'Projects',
    'Typologies',
    'Entities',
    'Layers',
    'Scenarios',
    'Reports'   
  ], ['client', 'server']);
});
