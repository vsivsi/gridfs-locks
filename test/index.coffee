# Unit tests

assert = require 'assert'
mongo = require 'mongodb'

Lock = require('../index').Lock
LockCollection = require('../index').LockCollection

describe 'test', () ->

  id = null
  db = null

  before (done) ->
    server = new mongo.Server 'localhost', 27017
    db = new mongo.Db 'gridfs_locks_test', server, {w:1}
    db.open done

  describe 'LockCollection', () ->

    it "should be a function", () ->
      assert 'function' is typeof LockCollection

    it "shouldn't create instances without the new keyword", () ->
      assert.throws (() -> LockCollection()), /LockCollections must be created using the/

    it "shouldn't create instances without having used the .created method", () ->
      assert.throws (() -> new LockCollection({})), /LockCollections must be created using the/
      assert.throws (() -> new LockCollection({},{})), /LockCollections must be created using the/

    it "should require a valid collection parameter", () ->
      assert.throws (() -> new LockCollection({}, { _created: true})), /Invalid collection parameter/

    describe 'LockCollection.create', () ->

      it "should require a valid mongo db connection object", () ->
        assert.throws (() -> LockCollection.create(null)), /db is not a valid Mongodb connection object/

      it "should require a non-falsy root to be a string", () ->
        assert.throws (() -> LockCollection.create(db, 1)), /root must be a string or falsy/

      it "should require a callback function", () ->
        assert.throws (() -> LockCollection.create(db, false, {})), /A callback function must be provided/

      it "should create a valid mongodb collection", (done) ->
        LockCollection.create db, false, {}, (e, lc) ->
          assert.equal typeof lc.collection.find, 'function'
          done()

      it "should properly index the .locks collection", (done) ->
        LockCollection.create db, false, {}, (e, lc) ->
          lc.collection.indexExists "files_id_1", (e, ii) ->
            assert.equal ii, true
            done()

      it "should use the default GridFS collection root when no root is given", (done) ->
        LockCollection.create db, false, {}, (e, lc) ->
          assert.equal lc.collection.collectionName, mongo.GridStore.DEFAULT_ROOT_COLLECTION + ".locks"
          done()

      it "should use the provided collection root name when given", (done) ->
        LockCollection.create db, 'test', {}, (e, lc) ->
          assert.equal lc.collection.collectionName, "test.locks"
          done()

      it "should properly record all options", (done) ->
        LockCollection.create db, null, { w: 16, timeOut: 16, pollingInterval: 16, lockExpiration: 16, metaData: 16 }, (e, lc) ->
          assert.equal lc.writeConcern, 16
          assert.equal lc.timeOut, 16
          assert.equal lc.pollingInterval, 16
          assert.equal lc.lockExpiration, 16
          assert.equal lc.metaData, 16
          done()

  describe 'Lock', () ->

  after (done) ->
    db.dropDatabase () ->
      db.close true, done