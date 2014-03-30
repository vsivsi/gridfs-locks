/***********************************************************************
     Copyright (C) 2014 by Vaughn Iverson
     gridfs-locks is free software released under the MIT/X11 license.
     See included LICENSE file for details.
************************************************************************/

//
// Parameters:
//
// collection: a valid mongodb collection object
// options object:
//    w:                mongo writeconcern  Default: 1
//    pollingInterval:  Seconds between successive attempts to acquire a lock while waiting  Default: 5 sec
//    lockExpiration:   Seconds until an unrenewed lock expires in the database  Default: Never
//    timeOut:          Seconds to poll when obtaining a lock that is not available.  Default: Do not poll
//    metaData:         side information to store in the lock documents, useful for debugging  Default: null
//
// NOTE! -- Do not create a LockCollection directly using new, use the 'create' static method below
//
var LockCollection = exports.LockCollection = function(collection, options) {

  var self = this;

  if(!(self instanceof LockCollection) || (!options || !options._created)) {
    throw new Error("LockCollections must be created using the 'LockCollection.create' static method")
    return;
  };

  if (typeof collection.find !== 'function') {
    throw new Error("Invalid collection parameter in LockCollection constructor")
    return;
  }

  self.writeConcern = options.w == null ? 1 : options.w;
  self.timeOut = options.timeOut || 0;                    // Locks do not poll by default
  self.pollingInterval = options.pollingInterval || 5;    // Secs
  self.lockExpiration = options.lockExpiration || 0;      // Never
  self.metaData = options.metaData || null;               // None
  self.collection = collection;

};

// Static method for creation / initialization of a new LockCollection object.
//
// Use of a static method is necessary because the constructor can't be asyncronous
//
// Parameters:
//
// db:   a valid mongodb connection object  Mandatory
// root: the string of the root mongodb collection name  Default: 'fs'
// options object:
//    w:                mongo writeconcern  Default: 1
//    pollingInterval:  Seconds between successive attempts to acquire a lock while waiting  Default: 3
//    lockExpiration:   Seconds until an unrenewed lock expires in the database  Default: 300
//    timeOut: Seconds to poll when obtaining a lock that is not available.  Default: 300
// callback: function(err, lockCollection)  Mandatory.
//
LockCollection.create = function(db, root, options, callback) {
  if (!db || typeof db.collection !== 'function') {
    throw new Error("db is not a valid Mongodb connection object.")
    return;
  }
  if (root && (typeof root !== 'string')) {
    throw new Error("root must be a string or falsy.")
    return;
  }
  if (typeof callback !== 'function') {
    throw new Error("A callback function must be provided")
    return;
  }

  options = options || {};
  options._created = true;   // flag that this method was called
  root = root || 'fs';
  collectionName = root + '.locks';
  db.collection(collectionName, function(err, collection) {
    if(err) return callback(err);
    // Ensure unique files_id so there can only be one lock doc per file
    collection.ensureIndex([['files_id', 1]], {unique:true}, function(err, index) {
      if(err) return callback(err);
      callback(null, new LockCollection(collection, options));
    });
  });
};

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
  if(!(this instanceof Lock)) return new Lock(fileId, lockCollection, options);
  if (!(lockCollection instanceof LockCollection)) {
    throw new Error("Invalid lockCollection object.");
    return;
  }

  var self = this;
  options = options || {};
  self.lockCollection = lockCollection;
  self.collection = lockCollection.collection;
  self.fileId = fileId;
  self.timeCreated = new Date();
  self.pollingInterval = options.pollingInterval || self.lockCollection.pollingInterval;
  self.lockExpiration = options.lockExpiration || self.lockCollection.lockExpiration || 8000000000000; // Never
  self.lockExpireTime = new Date(self.timeCreated.getTime() + self.lockExpiration*1000);  // Fails in 20000 years?!
  self.timeOut = options.timeOut || self.lockCollection.timeOut || 0; // Default to no timeout
  self.metaData = options.metaData || self.lockCollection.metaData;
  self.lockType = null;
  self.query = null;
  self.update = null;
  self.heldLock = null;
};

// Release a currently held lock.
//
// Parameters:
//
// callback: function(err, doc)  Mandatory.
//     doc: The new unheld lock document in the database
//
Lock.prototype.releaseLock = function(callback) {

  var self = this;
  var query = null,
      update = null;
  if (!(self.heldLock)) {
    return callback(new Error("Cannot release an unheld lock."));
  }
  if(self.lockType === 'r') {
    query = {files_id: self.fileId, read_locks: {$gt: 0}};
    update = {$inc: {read_locks: -1}, $set: {meta: null}};
  } else if(self.lockType[0] === 'w') {
    query = {files_id: self.fileId, write_lock: true};
    update = {$set: {write_lock: false, meta: null}};
  } else {
    return callback(new Error("Invalid lockType: " + self.lockType));
  }
  self.collection.findAndModify(query, [], update, {w: self.lockCollection.writeConcern, new: true}, function (err, doc) {
    self.lockType = null;
    self.query = null;
    self.update = null;
    self.heldLock = null;
    if (err == null && doc == null) {
      err = new Error("Lock document not found in collection");
    }
    callback(err, doc);
  });
};

// Prevent expiration of a held lock for another lockExpiration seconds
//
// This method is useful to keep alive the locks of longer running operations, permitting the default
// lockExpiration on a LockCollection to be relatively short so that dead locks may be eliminated.
//
// Parameters:
//
// callback: function(err, doc)  Mandatory.
//     doc: The renewed lock document in the database
//
Lock.prototype.renewLock = function(callback) {
  var self = this;
  if (!(self.heldLock)) {
    return callback(new Error("Cannot renew an unheld lock."));
  }
  self.lockExpireTime = new Date(new Date().getTime() + self.lockExpiration*1000);
  self.query = null;
  self.collection.findAndModify({files_id: self.fileId},
    [],
    {$set: {expires: self.lockExpireTime}},
    {w: self.lockCollection.writeConcern, new: true},
    function (err, doc) {
      self.heldLock = doc;
      if (err == null && doc == null) {
        err = new Error("Lock document not found in collection");
      }
      callback(err, doc);
    });
};

// Attempt to obtain a read (non-exclusive) lock on a resource
//
// obtainReadLock will poll MongoDB for an unavailable lock every pollingInterval seconds until
// it succeeds or times out after timeOut seconds of polling. Read locks may be obtained when there
// is no write_lock being held and when there are no active write_req. Any number of read locks
// for a resource may be held simultaneously.
//
// Parameters:
//
// callback: function(err, doc)  Mandatory.
//     doc: The obtained lock document in the database, or null if the timeout exceeded during polling
//
Lock.prototype.obtainReadLock = function(callback) {
  var self = this;
  if (self.heldLock) {
    return callback(new Error("Cannot obtain an already held lock."));
  }
  // Ensure that lock document for files_id exists
  initializeLockDoc(self, function (err, doc) {
    if(err) { return callback(err); }
    self.query = {files_id: self.fileId, $or: [{expires: {$lt: new Date(new Date() - 2000*self.lockCollection.pollingInterval)}}, {write_lock: false, write_req: false}]};
    self.update = {$inc: {read_locks: 1, reads: 1}, $set: {write_lock: false, write_req: false, expires: self.lockExpireTime, meta: self.metaData}};
    self.lockType = 'r';
    return timeoutQuery(self, callback);
  });
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
// callback: function(err, doc)  Mandatory.
//     doc: The obtained lock document in the database, or null if the timeout exceeded during polling
//
Lock.prototype.obtainWriteLock = function(callback) {

  var self = this;
  if (self.heldLock) {
    return callback(new Error("Cannot obtain an already held lock."));
  }
  // Ensure that lock document for files_id exists
  initializeLockDoc(self, function (err, doc) {
    if(err) { return callback(err); }
    self.query = {files_id: self.fileId, $or: [{expires: {$lt: new Date()}, write_req: true}, {write_lock: false, read_locks: 0}]};
    self.update = {$set: {write_lock: true, write_req: false, read_locks: 0, expires: self.lockExpireTime, meta: self.metaData}, $inc:{writes: 1}};
    self.lockType = 'w';

    return timeoutQuery(self, function (err, doc) {
      if(err || doc) return callback(err, doc);
      callback(err, null);
    });
  });
};

// Private function that ensures an initialized lock doc is in the database

var initializeLockDoc = function (self, callback) {
  self.lockExpireTime = new Date(new Date().getTime() + self.lockExpiration*1000);
  self.collection.findAndModify({files_id: self.fileId},
    [],
    {$setOnInsert: {files_id: self.fileId, expires: self.lockExpireTime, read_locks: 0, write_lock: false, write_req: false, reads: 0, writes: 0, meta: null}},
    {w: self.lockCollection.writeConcern, upsert: true, new: true},
    callback);
};

// Private function that implements polling for locks in the database

var timeoutQuery = function (self, callback) {
  self.update.$set.expires = self.lockExpireTime = new Date(new Date().getTime() + self.lockExpiration*1000);
  // Read locks can break writelocks with write_req after more than one polling cycle
  if (self.lockType === 'r') {
    self.query.$or[0].expires.$lt = new Date(new Date() - 2000*self.pollingInterval)
  } else {
    self.query.$or[0].expires.$lt = new Date();
  }
  self.collection.findAndModify(self.query, [], self.update, {w: self.lockCollection.writeConcern, new: true}, function (err, doc) {
    self.heldLock = doc;
    if(err || doc) return callback(err, doc);

    // keep trying until timeout
    if(new Date() - self.timeCreated > self.timeOut*1000) {
      console.log("Lock request timed out...", self.lockType, self.fileId);
      return callback(null, null);
    } else {
      if (self.lockType === 'w') {
        // write_req gets set every time because released write locks clear it
        self.collection.findAndModify({files_id: self.fileId, write_req: false},
          [],
          {$set: {write_req: true}},
          {new: true},
          function (err, doc) {
            if(err) { return callback(err); }
            return setTimeout(timeoutQuery, self.pollingInterval*1000, self, callback);
        });
      } else {
        return setTimeout(timeoutQuery, self.pollingInterval*1000, self, callback);
      }
    }
  });
};

