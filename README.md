# gridfs-locks

[![Build Status](https://travis-ci.org/vsivsi/gridfs-locks.svg)](https://travis-ci.org/vsivsi/gridfs-locks)

 `gridfs-locks` implements distributed and [fair read/write locking](https://en.wikipedia.org/wiki/Readers-writer_lock) based on [MongoDB](http://www.mongodb.org/), and is specifically designed to make MongoDB's [GridFS](http://docs.mongodb.org/manual/reference/gridfs/) file-store [safe for concurrent access](https://jira.mongodb.org/browse/NODE-157). It is a [node.js](http://nodejs.org/) [npm package](https://www.npmjs.org/package/gridfs-locks) built on top of the [native `mongodb` driver](https://www.npmjs.org/package/mongodb), and is compatible with the native [GridStore](https://github.com/mongodb/node-mongodb-native/blob/master/docs/gridfs.md) implementation.

NOTE: if you use [gridfs-stream](https://www.npmjs.org/package/gridfs-stream) and need the locking capabilities of this package (and you probably do... see the "Why?" section at the bottom of this README), you should check out [gridfs-locking-stream](https://www.npmjs.org/package/gridfs-locking-stream). It is basically gridfs-stream + gridfs-locks.

## What's new in v1.x
Following the [semantic versioning](http://semver.org/) convention, version 1.x contains a few breaking changes from the prototype v0.0.x of `gridfs-locks`. The main difference is that v1.x Lock and LockCollection objects are now [event-emitters](http://nodejs.org/api/events.html). There are three primary impacts of these changes:

1.    All async callbacks have been eliminated from the API method parameter lists and replaced with events
2.    A much richer set of async events (eg. lock expirations) can now be observed and handled in a more intuitive way
3.    Locks for removed resources can be also be removed so they don't clutter up the lock collection

### Installation

Requires node.js, npm, and uses the native node.js mongo driver.

    npm install gridfs-locks

To run unit tests (requires mongodb server on `localhost:27017`):

    npm test

## Use

```js
var Db = require('mongodb').Db;
var Server = require('mongodb').Server;
var db = new Db('test', new Server('127.0.0.1', 27017));
var LockCollection = require('gridfs-locks').LockCollection
var Lock = require('gridfs-locks').Lock

// Open the database
db.open(function(err, db) {

  // Setup GridStore, etc.

  // Create a lock collection alongside the GridFS collections
  var lockColl = LockCollection(db, { root: 'fs',
                                      timeOut: 60,
                                      pollingInterval: 5,
                                      lockExpiration: 30 });

  // Add error event handler for lockColl

  // 'ready' event when the collection is ready to use
  lockColl.on('ready', function () {

    var ID = something;  // ID is a unique _id (eg., a GridFS file _id)

    // Create a lock object for ID
    var lock = Lock(ID, lockColl, {}); // can override collection settings

    // Request a write lock
    lock.obtainWriteLock()

    // Event emitted when lock obtained
    lock.on('locked', function(ld) {

      // Write to a gridFS file, do generally unsafe things

      // Don't forget!
      lock.releaseLock();
    });

    // Another lock on same resource ID, use of 'new' is optional
    var lock2 = new Lock(ID, lockColl, {});

    // Request a read lock. Note calls can be chained...
    lock2.obtainReadLock().on('locked', function(ld) {

      // Read from a GridFS file, safe in the knowledge that some
      // concurrent writer isn't going to make you crash...

      // Release the lock, and then reuse it to remove the resource
      lock2.releaseLock().on('released', function () {
          lock2.obtainWriteLock().on('locked', function () {

              // Remove the file/resource/whatever

              lock2.removeLock(); // Remove the lock from the collection
            }
          );
        }
      );
    });

    // Add error and timed-out event handlers for lock and lock2

  });
});
```

## How it works (briefly)

GridFS itself creates [two collections](http://docs.mongodb.org/manual/reference/gridfs/) based off a root name (default root is `fs`) called e.g. `fs.files` and `fs.chunks`. `gridfs-locks` takes the same root name and creates a third collection (e.g. `fs.locks`) that contains documents used to provide robust locking. Internally, it uses the [MongoDB `findAndModify()` operation](http://docs.mongodb.org/manual/reference/method/db.collection.findAndModify/) to guarantee the atomicity of lock updates. `gridfs-locks` does not touch or even know about the `.files` and `.chunks` collections, and so it doesn't interfere with (or even require) a GridFS store to work. As an aside, for this reason it is completely general and can be used as a distributed locking scheme for any purpose, not just for making GridFS concurrency-safe.

It uses a [multiple-reader/exclusive-writer model for locking, with a fair write-request scheme](https://en.wikipedia.org/wiki/Readers-writer_lock) to prevent blocking of writes by a continuous stream of readers. There is optional support for lock expiration, attaching metadata to locks (for debugging distributed applications), and waiting to obtain locks with timeout. When waiting for locks, the polling interval is also configurable. All of the above options can be configured globally, or on a per-lock basis. As a bonus, `gridfs-locks` also tracks the number of successful read and write locks granted for each resource.

As with any locking scheme, care must be taken to avoid creating [deadlocks](https://en.wikipedia.org/wiki/Deadlocks), and the built-in lock expiration pattern may be helpful in doing so. The default configuration is that locks never expire, and attempts to obtain unavailable locks emit the `'timed-out'` event immediately without waiting for a lock to become available. These behaviors may be changed using the `lockExpiration`, `timeOut` and `pollingInterval` options.

## API

### LockCollection(db, options)

Create a new lock collection.

```js
// using 'new' is optional

var lockColl = new LockCollection(
  db,      // Must be an open mongodb connection object
  {                       // Options: All except 'root' can be overridden
    root: 'fs',           // root name for the collection.
                          // Default: 'fs'
    lockExpiration: 300,  // secs until a lock expires in the database
                          // Default: 0 (Never expire)
    timeOut: 30,          // secs to poll for an unavailable lock
                          // Default: 0 (Do not poll)
    pollingInterval: 5,   // secs between attempts to acquire a lock
                          // Default: 5 sec
    metaData: null        // any metadata to store in the lock documents
                          // Default: null
    w: 1                  // mongodb write-concern  Default: 1
  });

// Emits events:

// event: 'ready' - emitted when the collection is ready to use

lockColl.on('ready', function () {
  // Use collection to create/use locks, etc.
});

// event: 'error' - emitted in the case of a database or other unrecoverable
// error. 'ready' will not be emitted.  No listener for 'error' events will
// result in throws in case of errors (node.js default behavior)

lockColl.on('error', function (err) {
  // Handle error
});

```

### Lock()

Create a new Lock object. Lock objects may be reused, but are tied to a single Id for their lifetime.

```js

// using 'new' is optional

lock = new Lock(
  Id,         // Unique identifier for resource being locked.
              // Type must be compatible with mongodb `_id`
  lockColl,   // A valid LockCollection object
  {                       // Options:

    lockExpiration: 300,  // secs until a lock expires in the database
                          // Default: 0 (Never expire)
    timeOut: 30,          // secs to poll for an unavailable lock
                          // Default: 0 (Do not poll)
    pollingInterval: 5,   // secs between attempts to acquire a lock
                          // Default: 5 sec
    metaData: null        // any metadata to store in the lock document
                          // Default: null
  }
);

// Emits events:

// event: 'error' - emitted in the case of a database or other unrecoverable
// error. No listener for 'error' events will result in throws in case of
// errors, which is the node.js default behavior.

lock.on('error', function (err) {
  // Handle error
});

// event: 'locked' - A lock has been obtained. Supplies the current lock
// document. See obtainReadLock() and obtainWriteLock() methods below

lock.on('locked', function (ld) { // provides current lock document
  // Use locked resource...
});

// event: 'timed-out' - A timeout occurred while waiting to obtain an
// unavailable lock. This event only occurs when timeOut != 0
// See obtainReadLock() and obtainWriteLock() methods below

lock.on('timed-out', function () {
  // Handle timeout...
});

// event: 'released' - A held lock was successfully released
// see releaseLock() method below

lock.on('released', function (ld) {
  // do something else
});

// event: 'removed' - A held write lock was successfully removed from the
// lock collection. See removeLock() method below

lock.on('removed', function (ld) {
  // do something else
});

// The following three events only occur when lockExpiration != 0

// event: 'expires-soon' - warning ~90% of the lifetime of this lock has
// passed. Either release or renew the lock.
// See releaseLock() and renewLock() methods below

lock.on('expires-soon', function (ld) { // provides current lock document
  // release or renew...
});

// event: 'renewed' - A held lock was successfully renewed
// see renewLock() method below

lock.on('renewed', function (ld) {
  // continue using lock
});

// event: 'expired' - the lifetime of this lock has passed.
// It is no longer safe to use the underlying resource without obtaining
// a new lock

lock.on('expired', function (ld) {
  // handle expiration
});
```

### lock.obtainReadLock()

Attempt to obtain a non-exclusive lock on the resource. There can be multiple simultaneous readers of a resource.

```js
lock.obtainReadLock().on('locked',
  function (ld) {
    // Use lock
  }
).on('timed-out',
  function () {
    // Didn't get lock
  }
);
```

### lock.obtainWriteLock()

Attempt to obtain an exclusive lock on the resource. When a write lock is obtained, there can be no other readers or writers.

```js
lock.obtainWriteLock().on('locked',
  function (ld) {
    // Use lock
  }
).on('timed-out',
  function () {
    // Didn't get lock
  }
);
```

### lock.releaseLock()

Release a held lock, either read or write.

```js
lock.releaseLock().on('released',
  function (ld) {
    // No need to listen for this for no reason
  }
);
```

### lock.removeLock()

Remove a held write lock from the lock collection. Appropriate to use when the write lock is obtained to delete a resource.

```js
lock.removeLock().on('removed',
  function (ld) {
    // No need to listen for this for no reason
  }
);
```
### lock.renewLock()

Need more time? Reset the lock expiration time to `lockExpiration` seconds from now.

```js
lock.on('expires-soon',
  function() {
    lock.renewLock().on('renewed',
      function (ld) {
        if (ld) {
          // Keep using lock
        } else {
          // Lock couldn't be renewed
        }
      }
    );
  }
);
```

## Lock Document Data Model
```js
{
  files_id: Id,             // The id of the resource being locked
  expires: lockExpireTime,  // Date(), when this lock will expire
  read_locks: 0,            // Number of current read locks granted
  write_lock: false,        // Is there currently a write lock granted?
  write_req: false,         // Are there one or more write requests?
  reads: 0,                 // Successful read counter
  writes: 0,                // Successful write counter
  meta: null                // Application metadata
}
```

# Why?

I know what you're thinking:
-   why does there need to be yet another locking library for node?
-   why not do this using [Redis](http://redis.io/), or better yet use one of the [existing Redis solutions](https://github.com/search?q=redis+locks&search_target=global)?
-   wait, safe concurrent access [isn't already baked into MongoDB GridFS](https://jira.mongodb.org/browse/NODE-157)?

I'll answer these in reverse order... GridFS is MongoDB's file store technology; really it's just a bunch of "data model" conventions making it possible to store binary blobs of arbitrarily large non-JSON data in MongoDB collections. And it's totally useful.

However, the GridFS data model says nothing about how to safely synchronize attempted concurrent read/write access to stored files. This is a problem because GridFS uses two separate collections to store file metadata and data chunks, respectively. And since [MongoDB has no native support for atomic multi-operation transactions](http://docs.mongodb.org/manual/tutorial/isolate-sequence-of-operations/), this turns out to be a critical omission for almost any real-world use of GridFS.

The official node.js native mongo driver's [GridStore](https://github.com/mongodb/node-mongodb-native/blob/master/docs/gridfs.md) library is only "safe" (won't throw errors and/or corrupt GridFS data files) under two possible scenarios:

1.   Once created, files are strictly read-only. After the initial write, they can never be changed or deleted.
2.   An application **never** attempts to access a file when any kind of write or delete is also in progress.

Neither of these constraints is acceptable for most real applications likely to be built with node.js using MongoDB. The solution is an efficient and robust locking mechanism to enforce condition #2 above by properly synchronizing read/write accesses. That is what this package provides.

[Redis](http://redis.io/) is an amazing tool and this task could be certainly be done using Redis, but in this case we are already using MongoDB and it also has the capability to get the job done, so adding an unnecessary dependency on another server technology is undesirable.

I tailored this library to use MongoDB and mirror the GridFS data model in the hopes that it may inspire the MongoDB team to add official concurrency features to a future version of the GridFS specification. In the meantime, this library will hopefully suffice in making GridFS generally useful for real world applications. I welcome all feedback.
