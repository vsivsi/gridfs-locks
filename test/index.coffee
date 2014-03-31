# Unit tests

assert = require 'assert'
mongo = require 'mongodb'

Lock = require('../index').Lock
LockCollection = require('../index').LockCollection

describe 'gridfs-locks', () ->

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

      lc = null

      before (done) ->
        LockCollection.create db, false, {}, (e, lockColl) ->
          assert.ifError e
          lc = lockColl
          done()

      it "should require a valid mongo db connection object", () ->
        assert.throws (() -> LockCollection.create(null)), /db is not a valid Mongodb connection object/

      it "should require a non-falsy root to be a string", () ->
        assert.throws (() -> LockCollection.create(db, 1)), /root must be a string or falsy/

      it "should require a callback function", () ->
        assert.throws (() -> LockCollection.create(db, false, {})), /A callback function must be provided/

      it "should create a valid mongodb collection", () ->
        assert lc.collection?
        assert.equal typeof lc.collection.find, 'function'

      it "should properly index the .locks collection", (done) ->
        lc.collection.indexExists "files_id_1", (e, ii) ->
          assert.ifError e
          assert.equal ii, true
          done()

      it "should use the default GridFS collection root when no root is given", () ->
        assert.equal lc.collection.collectionName, mongo.GridStore.DEFAULT_ROOT_COLLECTION + ".locks"

      it "should have 6 keys", () ->
        assert.equal Object.keys(lc).length, 6

      it "should properly record all options", (done) ->
        LockCollection.create db, 'test', { w: 16, timeOut: 16, pollingInterval: 16, lockExpiration: 16, metaData: 16 }, (e, lc) ->
          assert.ifError e
          assert.equal lc.collection.collectionName, "test.locks"
          assert.equal lc.writeConcern, 16
          assert.equal lc.timeOut, 16
          assert.equal lc.pollingInterval, 16
          assert.equal lc.lockExpiration, 16
          assert.equal lc.metaData, 16
          done()

  describe 'Lock', () ->

    lockColl = null
    lock = null
    fileId = null

    before (done) ->
      fileId = new mongo.BSONPure.ObjectID
      LockCollection.create db, false, {}, (e, lc) ->
        assert.ifError e
        lockColl = lc
        lock = Lock fileId, lockColl, {}
        done()

    it "should be a function", () ->
      assert 'function' is typeof Lock

    it "should create instances without the new keyword", () ->
      assert lock instanceof Lock

    it "should have 13 keys", () ->
      assert.equal Object.keys(lock).length, 13

    it "should create a valid timeCreated Date", () ->
      assert lock.timeCreated instanceof Date

    it "should initialize state keys to null", () ->
      assert lock.lockType is null
      assert lock.query is null
      assert lock.update is null
      assert lock.heldLock is null

    it "should properly record all options", () ->
      l = new Lock fileId, lockColl, { timeOut: 16, pollingInterval: 16, lockExpiration: 16, metaData: 16 }
      assert.equal l.timeOut, 16000
      assert.equal l.pollingInterval, 16000
      assert.equal l.lockExpiration, 16000
      assert.equal l.metaData, 16
      assert.equal l.lockCollection, lockColl
      assert.equal l.collection, lockColl.collection
      assert.equal l.fileId, fileId

    describe 'obtainReadLock', () ->

      lock1 = null
      lock2 = null
      id = null

      before () ->
        id = new mongo.BSONPure.ObjectID
        lock1 = Lock id, lockColl, {}
        lock2 = Lock id, lockColl, {}

      it "should require a callback function", () ->
        assert.throws (() -> lock1.obtainReadLock()), /A callback function must be provided/

      it "should return a valid lock document", (done) ->
        lock1.obtainReadLock (e, ld) ->
          assert.ifError e
          assert ld?
          assert id.equals ld.files_id
          assert ld.expires instanceof Date
          assert ld.expires > lock1.timeCreated
          assert.equal ld.read_locks, 1
          assert.equal ld.write_lock, false
          assert.equal ld.write_req, false
          assert.equal ld.reads, 1
          assert.equal ld.writes, 0
          assert.equal ld.meta, null
          assert.equal lock1.heldLock, ld
          done()

      it "should properly set the lock state on a held read lock", () ->
        assert.equal lock1.lockType, 'r'
        assert lock1.query?
        assert lock1.update?

      it "should fail to return a second lock document for a lock object that already holds a lock", (done) ->
        lock1.obtainReadLock (e, ld) ->
          assert not ld?
          assert.throws (() -> throw e), /Cannot obtain an already held lock/
          done()

      it "should return a valid second read lock on a different lock object", (done) ->
        lock2.obtainReadLock (e, ld) ->
          assert.ifError e
          assert ld?
          assert id.equals ld.files_id
          assert ld.expires instanceof Date
          assert ld.expires > lock2.timeCreated
          assert.equal ld.read_locks, 2
          assert.equal ld.write_lock, false
          assert.equal ld.write_req, false
          assert.equal ld.reads, 2
          assert.equal ld.writes, 0
          assert.equal ld.meta, null
          assert.equal lock2.heldLock, ld
          done()

      describe 'releaseLock', () ->
        it "should return a valid lock document", (done) ->
          lock2.releaseLock (e, ld) ->
            assert.ifError e
            assert ld?
            assert id.equals ld.files_id
            assert ld.expires instanceof Date
            assert ld.expires > lock2.timeCreated
            assert.equal ld.read_locks, 1
            assert.equal ld.write_lock, false
            assert.equal ld.write_req, false
            assert.equal ld.reads, 2
            assert.equal ld.writes, 0
            assert.equal ld.meta, null
            done()

        it "should properly clear the lock state on a released read lock", () ->
          assert.equal lock2.lockType, null
          assert.equal lock2.query, null
          assert.equal lock2.update, null
          assert.equal lock2.heldLock, null

      describe 'obtainWriteLock', () ->
        it "should fail to return a valid write lock", (done) ->
          lock2.obtainWriteLock (e, ld) ->
            assert.ifError e
            assert.equal ld, null
            done()

    describe 'obtainWriteLock', () ->

      lock1 = null
      lock2 = null
      id = null

      before () ->
        id = new mongo.BSONPure.ObjectID
        lock1 = Lock id, lockColl, {}
        lock2 = Lock id, lockColl, {}

      it "should require a callback function", () ->
        assert.throws (() -> lock1.obtainWriteLock()), /A callback function must be provided/

      it "should return a valid lock document", (done) ->
        lock1.obtainWriteLock (e, ld) ->
          assert.ifError e
          assert ld?
          assert id.equals ld.files_id
          assert ld.expires instanceof Date
          assert ld.expires > lock1.timeCreated
          assert.equal ld.read_locks, 0
          assert.equal ld.write_lock, true
          assert.equal ld.write_req, false
          assert.equal ld.reads, 0
          assert.equal ld.writes, 1
          assert.equal ld.meta, null
          assert.equal lock1.heldLock, ld
          done()

      it "should properly set the lock state on a held write lock", () ->
        assert.equal lock1.lockType, 'w'
        assert lock1.query?
        assert lock1.update?

      it "should fail to return a second lock document for a lock object that already holds a lock", (done) ->
        lock1.obtainWriteLock (e, ld) ->
          assert not ld?
          assert.throws (() -> throw e), /Cannot obtain an already held lock/
          done()

      it "should fail to return a valid second write lock", (done) ->
        lock2.obtainWriteLock (e, ld) ->
          assert.ifError e
          assert.equal ld, null
          done()

      it "obtainReadLock should fail to return a valid read lock", (done) ->
        lock2.obtainReadLock (e, ld) ->
          assert.ifError e
          assert.equal ld, null
          done()

      describe 'releaseLock', () ->
        it "should return a valid lock document", (done) ->
          lock1.releaseLock (e, ld) ->
            assert.ifError e
            assert ld?
            assert id.equals ld.files_id
            assert ld.expires instanceof Date
            assert ld.expires > lock1.timeCreated
            assert.equal ld.read_locks, 0
            assert.equal ld.write_lock, false
            assert.equal ld.write_req, false
            assert.equal ld.reads, 0
            assert.equal ld.writes, 1
            assert.equal ld.meta, null
            done()

        it "should properly clear the lock state on a released read lock", () ->
          assert.equal lock1.lockType, null
          assert.equal lock1.query, null
          assert.equal lock1.update, null
          assert.equal lock1.heldLock, null

    describe 'releaseLock', () ->
      lock1 = null
      lock2 = null
      id = null
      id2 = null

      before (done) ->
        id = new mongo.BSONPure.ObjectID
        id2 = new mongo.BSONPure.ObjectID
        lock1 = Lock id, lockColl, {}
        lock2 = Lock id, lockColl, {}
        lock2.obtainReadLock (e, ld) ->
          assert.ifError e
          assert ld?
          done()

      it "should fail if callback is not a function", () ->
        assert.throws (() -> lock1.releaseLock("callback")), /Callback must be a function/

      it "should fail to release an unheld lock (with callback)", (done) ->
        lock1.releaseLock (e, ld) ->
          assert not ld?
          assert.throws (() -> throw e), /Cannot release an unheld lock/
          done()

      it "should fail to release an unheld lock (without callback)", () ->
        assert.throws (() -> lock1.releaseLock()), /Cannot release an unheld lock/

      it "should tolerate an omitted callback function for successful release", (done) ->
        lock1.obtainReadLock (e, ld) ->
          assert.ifError e
          assert ld?
          lock1.releaseLock()
          done()

      it "should fail on unsupported lockType (without callback)", () ->
        lock2.lockType = "X"
        assert.throws (() -> lock2.releaseLock()), /Invalid lockType/
        lock2.lockType = "r"

      it "should fail on unsupported lockType (with callback)", (done) ->
        lock2.lockType = "X"
        lock2.releaseLock (e, ld) ->
          assert not ld?
          assert.throws (() -> throw e), /Invalid lockType/
          lock2.lockType = "r"
          done()

      it "should fail on missing lock document", (done) ->
        lock2.fileId = id2
        lock2.releaseLock (e, ld) ->
          assert not ld?
          assert.throws (() -> throw e), /Lock document not found in collection/
          done()

    describe 'renewLock', () ->
      lock1 = null
      id = null

      before (done) ->
        id = new mongo.BSONPure.ObjectID
        lock1 = Lock id, lockColl, { lockExpiration: 60 }
        lock1.obtainReadLock (e, ld) ->
          assert.ifError e
          assert ld?
          done()

      it "should require a callback function", () ->
        assert.throws (() -> lock1.renewLock()), /A callback function must be provided/

      it "should successfully extend the lock time", (done) ->
        expiresBefore = lock1.heldLock.expires
        lock1.renewLock (e, ld) ->
          assert expiresBefore < ld.expires
          assert.equal ld.expires, lock1.heldLock.expires
          done()

      it "should fail to renew an unheld lock", (done) ->
        lock1.releaseLock (e, ld) ->
          lock1.renewLock (e, ld) ->
            assert.throws (() -> throw e), /Cannot renew an unheld lock/
            done()

  describe 'waiting for locks', () ->

    this.timeout 5000
    lockColl = null
    lock1 = null
    lock2 = null
    lock3 = null
    id = null

    before (done) ->
      LockCollection.create db, false, { timeOut: 2, pollingInterval: 1 }, (e, lc) ->
        assert.ifError e
        lockColl = lc
        done()

    beforeEach () ->
      id = new mongo.BSONPure.ObjectID
      lock1 = Lock id, lockColl, {}
      lock2 = Lock id, lockColl, {}
      lock3 = Lock id, lockColl, {}
      # These are too fast for production, but speed up the tests
      lock1.pollingInterval = 100
      lock2.pollingInterval = 100
      lock3.pollingInterval = 100

    it "should work for a write request waiting on a read lock", (done) ->
      expectedOrder = "1122"
      order = ''
      lock1.obtainReadLock (e, ld) ->
        assert.ifError e
        assert ld?
        order += '1'
        lock2.obtainWriteLock (e, ld) ->
          assert.ifError e
          assert ld?
          order += '2'
          lock2.releaseLock (e, ld) ->
            assert.ifError e
            assert ld?
            order += '2'
            assert.equal order, expectedOrder
            done()
        lock1.releaseLock (e, ld) ->
          assert.ifError e
          assert ld?
          order += '1'

    it "should work for a write request waiting on multiple read locks", (done) ->
      expectedOrder = "122133"
      order = ''
      lock1.obtainReadLock (e, ld) ->
        assert.ifError e
        assert ld?
        order += '1'
        lock2.obtainReadLock (e, ld) ->
          assert.ifError e
          assert ld?
          order += '2'
          lock3.obtainWriteLock (e, ld) ->
            assert.ifError e
            assert ld?
            order += '3'
            lock3.releaseLock (e, ld) ->
              assert.ifError e
              assert ld?
              order += '3'
              assert order is expectedOrder
              done()
          lock2.releaseLock (e, ld) ->
            assert.ifError e
            assert ld?
            order += '2'
            lock1.releaseLock (e, ld) ->
              assert.ifError e
              assert ld?
              order += '1'

    it "should work for a read request waiting on a write lock", (done) ->
      expectedOrder = "1122"
      order = ''
      lock1.obtainWriteLock (e, ld) ->
        assert.ifError e
        assert ld?
        order += '1'
        lock2.obtainReadLock (e, ld) ->
          assert.ifError e
          assert ld?
          order += '2'
          lock2.releaseLock (e, ld) ->
            assert.ifError e
            assert ld?
            order += '2'
            assert.equal order, expectedOrder
            done()
        lock1.releaseLock (e, ld) ->
          assert.ifError e
          assert ld?
          order += '1'

    it "should give priority to a write request waiting on a read lock over a subsequent read request", (done) ->
      expectedOrder = "112233"
      order = ''
      lock1.obtainReadLock (e, ld) ->
        assert.ifError e
        assert ld?
        order += '1'
        lock2.obtainWriteLock ((e, ld) ->
            assert.ifError e
            assert ld?
            order += '2'
            lock2.releaseLock (e, ld) ->
              assert.ifError e
              assert ld?
              order += '2'),
          { testingCallback: (() -> # This testing callback happens once the lock2 write request is written
            lock3.obtainReadLock (e, ld) ->
              assert.ifError e
              assert ld?
              order += '3'
              lock3.releaseLock (e, ld) ->
                assert.ifError e
                assert ld?
                order += '3'
                assert.equal order, expectedOrder
                done()
            lock1.releaseLock (e, ld) ->
              assert.ifError e
              assert ld?
              order += '1')}

    it "should give priority to a write request waiting on a write lock over a subsequent read request", (done) ->
      expectedOrder = "112233"
      order = ''
      lock1.obtainWriteLock (e, ld) ->
        assert.ifError e
        assert ld?
        order += '1'
        lock2.obtainWriteLock ((e, ld) ->
            assert.ifError e
            assert ld?
            order += '2'
            lock2.releaseLock (e, ld) ->
              assert.ifError e
              assert ld?
              order += '2'),
          { testingCallback: (() -> # This testing callback happens once the lock2 write request is written
            lock3.obtainReadLock (e, ld) ->
              assert.ifError e
              assert ld?
              order += '3'
              lock3.releaseLock (e, ld) ->
                assert.ifError e
                assert ld?
                order += '3'
                assert.equal order, expectedOrder
                done()
            lock1.releaseLock (e, ld) ->
              assert.ifError e
              assert ld?
              order += '1')}

    it "should allow a read request to proceed when a prior write request times out", (done) ->
      expectedOrder = "1331"
      order = ''
      lock2.timeOut = 150
      lock1.obtainReadLock (e, ld) ->
        assert.ifError e
        assert ld?
        order += '1'
        lock2.obtainWriteLock ((e, ld) ->
            # This write lock request should time out
            assert.ifError e
            assert not ld?),
          { testingCallback: (() -> # This testing callback happens once the lock2 write request is written
            lock3.obtainReadLock (e, ld) ->
              assert.ifError e
              assert ld?
              order += '3'
              lock3.releaseLock (e, ld) ->
                assert.ifError e
                assert ld?
                order += '3'
                lock1.releaseLock (e, ld) ->
                  assert.ifError e
                  assert ld?
                  order += '1'
                  assert.equal order, expectedOrder
                  done())}

  describe 'lock expiration', () ->

    this.timeout 5000

    lockColl = null
    lock1 = null
    lock2 = null
    lock3 = null
    id = null

    before (done) ->
      LockCollection.create db, false, { timeOut: 2, pollingInterval: 1, lockExpiration: 1 }, (e, lc) ->
        assert.ifError e
        lockColl = lc
        done()

    beforeEach () ->
      id = new mongo.BSONPure.ObjectID
      lock1 = Lock id, lockColl, {}
      lock2 = Lock id, lockColl, {}
      lock3 = Lock id, lockColl, {}
      # These are too fast for production, but speed up the tests
      lock1.pollingInterval = 100
      lock2.pollingInterval = 100
      lock3.pollingInterval = 100
      lock1.lockExpiration = 250
      lock2.lockExpiration = 250
      lock3.lockExpiration = 250

    it "should work for a write request waiting on a dead read lock", (done) ->
      expectedOrder = "122"
      order = ''
      lock1.obtainReadLock (e, ld) ->
        assert.ifError e
        assert ld?
        order += '1'
        lock2.obtainWriteLock (e, ld) ->
          assert.ifError e
          assert ld?
          order += '2'
          lock2.releaseLock (e, ld) ->
            assert.ifError e
            assert ld?
            order += '2'
            assert.equal order, expectedOrder
            done()

    it "should work for a write request waiting on multiple dead read locks", (done) ->
      expectedOrder = "1233"
      order = ''
      lock1.obtainReadLock (e, ld) ->
        assert.ifError e
        assert ld?
        order += '1'
        lock2.obtainReadLock (e, ld) ->
          assert.ifError e
          assert ld?
          order += '2'
          lock3.obtainWriteLock (e, ld) ->
            assert.ifError e
            assert ld?
            order += '3'
            lock3.releaseLock (e, ld) ->
              assert.ifError e
              assert ld?
              order += '3'
              assert order is expectedOrder
              done()

    it "should work for a read request waiting on a dead write lock", (done) ->
      expectedOrder = "122"
      order = ''
      lock1.obtainWriteLock (e, ld) ->
        assert.ifError e
        assert ld?
        order += '1'
        lock2.obtainReadLock (e, ld) ->
          assert.ifError e
          assert ld?
          order += '2'
          lock2.releaseLock (e, ld) ->
            assert.ifError e
            assert ld?
            order += '2'
            assert.equal order, expectedOrder
            done()

    it "should give priority to a write request waiting on a dead read lock over a subsequent read request", (done) ->
      expectedOrder = "12233"
      order = ''
      lock1.obtainReadLock (e, ld) ->
        assert.ifError e
        assert ld?
        order += '1'
        lock2.obtainWriteLock ((e, ld) ->
            assert.ifError e
            assert ld?
            order += '2'
            lock2.releaseLock (e, ld) ->
              assert.ifError e
              assert ld?
              order += '2'),
          { testingCallback: (() -> # This testing callback happens once the lock2 write request is written
            lock3.obtainReadLock (e, ld) ->
              assert.ifError e
              assert ld?
              order += '3'
              lock3.releaseLock (e, ld) ->
                assert.ifError e
                assert ld?
                order += '3'
                assert.equal order, expectedOrder
                done())}

    it "should give priority to a write request waiting on a dead write lock over a subsequent read request", (done) ->
      expectedOrder = "12233"
      order = ''
      lock1.obtainWriteLock (e, ld) ->
        assert.ifError e
        assert ld?
        order += '1'
        lock2.obtainWriteLock ((e, ld) ->
            assert.ifError e
            assert ld?
            order += '2'
            lock2.releaseLock (e, ld) ->
              assert.ifError e
              assert ld?
              order += '2'),
          { testingCallback: (() -> # This testing callback happens once the lock2 write request is written
            lock3.obtainReadLock (e, ld) ->
              assert.ifError e
              assert ld?
              order += '3'
              lock3.releaseLock (e, ld) ->
                assert.ifError e
                assert ld?
                order += '3'
                assert.equal order, expectedOrder
                done())}

    it "should allow a read request to proceed when a prior write request dies without releasing write_req", (done) ->
      expectedOrder = "1331"
      order = ''
      lock2.timeOut = 150
      lock1.obtainReadLock (e, ld) ->
        assert.ifError e
        assert ld?
        order += '1'
        lock2.obtainWriteLock ((e, ld) ->
            # This write lock request should time out
            assert.ifError e
            assert not ld?),
          { testWriteReq: true, testingCallback: (() -> # This testing callback happens once the lock2 write request is written
            lock3.obtainReadLock (e, ld) ->
              assert.ifError e
              assert ld?
              order += '3'
              lock3.releaseLock (e, ld) ->
                assert.ifError e
                assert ld?
                order += '3'
                lock1.releaseLock (e, ld) ->
                  assert.ifError e
                  assert ld?
                  order += '1'
                  assert.equal order, expectedOrder
                  done())}

    it "should allow a read request to proceed when a prior write request dies waiting for a dead write lock without releasing write_req", (done) ->
      expectedOrder = "133"
      order = ''
      lock2.timeOut = 150
      lock1.obtainWriteLock (e, ld) ->
        assert.ifError e
        assert ld?
        order += '1'
        lock2.obtainWriteLock ((e, ld) ->
            # This write lock request should time out
            assert.ifError e
            assert not ld?),
          { testWriteReq: true, testingCallback: (() -> # This testing callback happens once the lock2 write request is written
            lock3.obtainReadLock (e, ld) ->
              assert.ifError e
              assert ld?
              order += '3'
              lock3.releaseLock (e, ld) ->
                assert.ifError e
                assert ld?
                order += '3'
                assert.equal order, expectedOrder
                done())}

  after (done) ->
    db.dropDatabase () ->
      db.close true, done

