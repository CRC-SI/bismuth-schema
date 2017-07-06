Package.describe({
  name: 'crc4si:bismuth-schema',
  summary: 'Schemas and collections for working with GIS apps.',
  git: 'https://github.com/crc-si/bismuth-schema.git',
  version: '0.1.0'
});

Package.on_use(function(api) {
  api.versionsFrom('METEOR@0.9.0');
  api.use([
    'check',
    'coffeescript',
    'underscore',
    'reactive-var@1.0.11',
    'tracker@1.1.3',
    'aldeed:collection2@2.3.1',
    'aldeed:simple-schema@1.1.0',
    'aramk:pubsub@1.5.0',
    'aramk:q@1.0.1_1',
    'aramk:utility@0.6.0',
    'matb33:collection-hooks@0.7.6',
    'urbanetic:accounts-ui@0.2.2',
    'crc4si:atlas-util@0.3.0',
    'crc4si:bismuth-schema-utility@0.1.0'
  ], ['client', 'server']);
  api.use([
    'session'
  ], 'client')
  api.addFiles([
    'src/Units.coffee',
    'src/Projects.coffee',
    'src/util/ScenarioUtils.coffee',
    'src/Scenarios.coffee',
    'src/schemas/TypologySchema.coffee',
    'src/Typologies.coffee',
    'src/schemas/EntitySchema.coffee',
    'src/Layers.coffee',
    'src/Entities.coffee',
    'src/Reports.coffee',
    'src/util/LayerUtils.coffee',
    'src/util/CollectionUtils.coffee'
  ], ['client', 'server']);
  api.addFiles([
    'src/server/projects.coffee',
    'src/server/publications.coffee',
    'src/server/scenarios.coffee'
  ], ['server']);
  api.export([
    'Units',
    'Projects',
    'ScenarioUtils',
    'Scenarios',
    'TypologySchema',
    'Typologies',
    'EntitySchema',
    'Layers',
    'Entities',
    'Reports',
    'LayerUtils',
    'CollectionUtils'
  ], ['client', 'server']);
});
