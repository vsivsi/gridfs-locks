/***********************************************************************
     Copyright (C) 2014 by Vaughn Iverson
     gridfs-locks is free software released under the MIT/X11 license.
     See included LICENSE file for details.
************************************************************************/

var eventEmitter = require('events').EventEmitter;

var never = 8000000000000000;  // never + now = 20000 years shy of max Date(), about 250,000 years from now

//
// Parameters:
//
// db:   a valid mongodb connection object  Mandatory
// options object:
//    root:             the string of the root mongodb collection name  Default: 'fs'
//    w:                mongo writeconcern  Default: 1
//    pollingInterval:  Seconds between successive attempts to acquire a lock while waiting  Default: 5 sec
//    lockExpiration:   Seconds until an unrenewed lock expires in the database  Default: Never
//    timeOut:          Seconds to poll when obtaining a lock that is not available.  Default: Do not poll
//    metaData:         side information to store in the lock documents, useful for debugging  Default: null
//
var LockCollection = exports.LockCollection = function(db, options) {
  var self = this;
  if (!(self instanceof LockCollection)) { return new LockCollection(db, options); }

  eventEmitter.call(self);  // We are an eventEmitter

  if (!db || typeof db.collection !== 'function') {
    return emitError(self, "LockCollection 'db' parameter must be a valid Mongodb connection object.");
  }

  if (options && typeof options !== 'object') {
    return emitError(self, "LockCollection 'options' parameter must be an object.");
  }

  options = options || {};

  if (options.root && (typeof options.root !== 'string')) {
    return emitError(self, "LockCollection 'options.root' must be a string or falsy.");
  }

  options.root = options.root || 'fs';
  collectionName = options.root + '.locks';
  db.collection(collectionName, function(err, collection) {

    if (err) { return emitError(self, err); }

    // Ensure unique files_id so there can only be one lock doc per file
    collection.ensureIndex([['files_id', 1]], {unique:true}, function(err, index) {

      if (err) { return emitError(self, err); }
      self.collection = collection;
      self.emit('ready');
    });
  });

  self.writeConcern = options.w == null ? 1 : options.w;
  self.timeOut = options.timeOut || 0;                  // Locks do not poll by default
  self.pollingInterval = options.pollingInterval || 5;  // 5 secs
  self.lockExpiration = options.lockExpiration || 0;    // Never
  self.metaData = options.metaData || null;             // None

  return self;
};

LockCollection.prototype = eventEmitter.prototype;

// Create a new Lock object
//
// Parameters:
//
// fileId:         Unique identifier of the resource being locked  Mandatory
// lockCollection: Valid LockCollection object
// options:
//          timeOut: Seconds to poll when obtaining a lock that is not available.  Default: 600
//          lockExpiration: Seconds until an unrenewed lock expires in the database  Default: Never
//          pollingInterval: Seconds between successive attempts to acquire a lock while waiting  Default: 5
//          metaData: side information to store in the lock document, useful for debugging  Default: null
//
var Lock = exports.Lock = function(fileId, lockCollection, options) {

  if (!(this instanceof Lock)) return new Lock(fileId, lockCollection, options);

  var self = this;

  if (options && typeof options !== 'object') {
    return emitError(self, "Lock 'options' parameter must be an object.");
  }

  if (!(lockCollection instanceof LockCollection)) {
    return emitError(self, "Lock invalid 'lockCollection' object.");
  }

  if (!lockCollection.collection) {
    return emitError(self, "Lock 'lockCollection' must be 'ready'.");
  }

  options = options || {};
  self.lockCollection = lockCollection;
  self.collection = lockCollection.collection;
  self.fileId = fileId;
  self.timeCreated = new Date();
  self.pollingInterval = 1000*(options.pollingInterval || self.lockCollection.pollingInterval);
  self.lockExpiration = 1000*(options.lockExpiration || self.lockCollection.lockExpiration);
  self.lockExpireTime = new Date(self.timeCreated.getTime() + (self.lockExpiration || never));
  self.timeOut = 1000*(options.timeOut || self.lockCollection.timeOut);
  self.metaData = options.metaData || self.lockCollection.metaData;
  self.lockType = null;
  self.query = null;
  self.update = null;
  self.heldLock = null;
  return self;
};

Lock.prototype = eventEmitter.prototype;

// Release a currently held lock.
//
// Parameters:  None
//
// Emits:
//    'released':
//         doc: The new unheld lock document in the database
//    'error':
//         err: Any error that occurs
//
Lock.prototype.releaseLock = function () {

  var self = this;
  var query = null,
      update = null;

  if (!(self.heldLock)) {
    return emitError(self, "Lock.releaseLock cannot release an unheld lock.");
  }
  if(self.lockType === 'r') {
    query = {files_id: self.fileId, read_locks: {$gt: 0}};
    update = {$inc: {read_locks: -1}, $set: {meta: null}};
  } else if(self.lockType[0] === 'w') {
    query = {files_id: self.fileId, write_lock: true};
    update = {$set: {write_lock: false, meta: null}};
  } else {
    return emitError(self, "Lock.releaseLock invalid lockType.");
  }
  self.collection.findAndModify(query, [], update, {w: self.lockCollection.writeConcern, new: true}, function (err, doc) {
    if (err) { return emitError(self, err); }

    self.lockType = null;
    self.query = null;
    self.update = null;
    self.heldLock = null;
    if (doc == null) {
      return emitError(self, "Lock.releaseLock Lock document not found in collection.");
    }

    self.emit('released', doc);
  });
  return self;  // allow chaining
};

// Prevent expiration of a held lock for another lockExpiration seconds
//
// This method is useful to keep alive the locks of longer running operations, permitting the default
// lockExpiration on a LockCollection to be relatively short so that dead locks may be eliminated.
//
// Parameters:  None
//
// Emits:
//    'renewed':
//         doc: The new unheld lock document in the database
//    'error':
//         err: Any error that occurs
//
Lock.prototype.renewLock = function() {
  var self = this;
  if (!(self.heldLock)) {
    return emitError(self, "Lock.renewLock cannot renew an unheld lock.");
  }
  if (!(self.lockExpiration)) {
    return emitError(self, "Lock.renewLock cannot renew a non-expiring lock.");
  }
  self.lockExpireTime = new Date(new Date().getTime() + self.lockExpiration);
  self.query = null;
  self.collection.findAndModify({files_id: self.fileId},
    [],
    {$set: {expires: self.lockExpireTime}},
    {w: self.lockCollection.writeConcern, new: true},
    function (err, doc) {
      if (err) { return emitError(self, err); }
      self.heldLock = doc;
      if (doc == null) {
        return emitError(self, "Lock.renewLock document not found in collection");
      }
      self.emit('renewed', doc);
    });
  return self;
};

// Attempt to obtain a read (non-exclusive) lock on a resource
//
// obtainReadLock will poll MongoDB for an unavailable lock every pollingInterval seconds until
// it succeeds or times out after timeOut seconds of polling. Read locks may be obtained when there
// is no write_lock being held and when there are no active write_req. Any number of read locks
// for a resource may be held simultaneously.
//
// Emits:
//    'locked':
//          doc: The obtained lock document in the database
//    'timed-out':
//          null
//    'expired':
//          null - This lock is no longer valid due to expiration
//    'error':
//          err: Any error that occurs
//
Lock.prototype.obtainReadLock = function() {
  var self = this;
  if (self.heldLock) {
    return emitError(self, "Lock.obtainReadLock cannot obtain an already held lock.");
  }
  // Ensure that lock document for files_id exists
  initializeLockDoc(self, function (err, doc) {
    if (err) { return emitError(self, err); }
    self.query = {files_id: self.fileId, $or: [{expires: {$lt: new Date(new Date() - 2000*self.lockCollection.pollingInterval)}}, {write_lock: false, write_req: false}]};
    self.update = {$inc: {read_locks: 1, reads: 1}, $set: {write_lock: false, write_req: false, expires: self.lockExpireTime, meta: self.metaData}};
    self.lockType = 'r';
    timeoutQuery(self);
  });
  return self;
};

// Attempt to obtain a write (exclusive) lock on a resource
//
// obtainWriteLock will poll MongoDB for an unavailable lock every pollingInterval seconds until
// it succeeds or times out after timeOut seconds of polling. A write lock may be obtained when
// there are no read or write locks currently held on a resource. Write locks have priority in that
// a polling request for a write lock will block new read locks from being granted via the write_req
// field in the lock document. Only one write lock for a resource may be held at a time.
//
// Parameters:
//
// testingOptions: Unit Testing options:
//    testCallback: optional, used by Unit testing to have a hook after the write request is written
//       no params
//    testWriteReq: optional, if true, supresses the clearing of the write_req lock when a write lock request times out
//
// Emits:
//    'locked':
//          doc: The obtained lock document in the database
//    'timed-out':
//          null - No parameters in callback
//    'expired':
//          null - This lock is no longer valid due to expiration
//    'error':
//          err: Any error that occurs
//
Lock.prototype.obtainWriteLock = function(testingOptions) {
  var self = this;
  if (self.heldLock) {
    return emitError(self, "Lock.obtainWriteLock cannot obtain an already held lock.");
  }
  testingOptions = testingOptions || {};
  // Ensure that lock document for files_id exists
  initializeLockDoc(self, function (err, doc) {
    if (err) { return emitError(self, err); }
    self.query = {files_id: self.fileId, $or: [{expires: {$lt: new Date()}, write_req: true}, {write_lock: false, read_locks: 0}]};
    self.update = {$set: {write_lock: true, write_req: false, read_locks: 0, expires: self.lockExpireTime, meta: self.metaData}, $inc:{writes: 1}};
    self.lockType = 'w';
    timeoutQuery(self, testingOptions);
  });
  return self;
};

// Private function to help with properly emitting errors

var emitError = function (self, err) {
  if (typeof err == 'string') err = new Error(err);
  setImmediate(function () { self.emit('error', err); });
  return self;
}

// Private function that ensures an initialized lock doc is in the database

var initializeLockDoc = function (self, callback) {
  self.lockExpireTime = new Date(new Date().getTime() + (self.lockExpiration || never));
  self.collection.findAndModify({files_id: self.fileId},
    [],
    {$setOnInsert: {files_id: self.fileId, expires: self.lockExpireTime, read_locks: 0, write_lock: false, write_req: false, reads: 0, writes: 0, meta: null}},
    {w: self.lockCollection.writeConcern, upsert: true, new: true},
    callback);
};

// Private function that implements polling for locks in the database

var timeoutQuery = function (self, options) {
  options = options || {};
  self.update.$set.expires = self.lockExpireTime = new Date(new Date().getTime() + (self.lockExpiration || never));
  // Read locks can break writelocks with write_req after more than one polling cycle
  if (self.lockType === 'r') {
    self.query.$or[0].expires.$lt = new Date(new Date() - 2*self.pollingInterval)
  } else {
    self.query.$or[0].expires.$lt = new Date();
  }
  self.collection.findAndModify(self.query, [], self.update, {w: self.lockCollection.writeConcern, new: true}, function (err, doc) {
    if (err) { return emitError(self, err); }
    if (doc) {
      self.heldLock = doc;
      return self.emit('locked', doc);
    }

    if (self.lockType === 'w') {
      if(new Date() - self.timeCreated > self.timeOut) {
        if (!options.testWriteReq) {
          // Clear the write_req flag, since this obtainWriteLock has timed out
          self.collection.findAndModify({files_id: self.fileId, write_req: true}, [], {$set: {write_req: false }}, {w: self.lockCollection.writeConcern, new: true}, function (err, doc) {
            if (err) { return emitError(self, err); }
          });
        }
        return self.emit('timed-out');
      } else {
        // write_req gets set every time because claimed write locks and timed out write requests clear it
        self.collection.findAndModify({files_id: self.fileId, write_req: false},
          [],
          {$set: {write_req: true}},
          {new: true},
          function (err, doc) {
            if (err) { return emitError(self, err); }
            self.emit('write-req-set');
        });
      }
    } else {
      if(new Date() - self.timeCreated > self.timeOut) {
        return self.emit('timed-out');
      }
    }

    setTimeout(timeoutQuery, self.pollingInterval, self);

  });
};

