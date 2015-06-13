### 1.3.4

- Added Travis CI automated Testing
- Updated npm dependencies
- Fixed license ID in package file

### 1.3.3

- Fixed improper emitted errors in `lock.renewLock()` caused by race conditions with lock release / remove

### 1.3.2

- Fixed race issue when mutliple clients simultaneously create new LockCollections backed by the same mongodb server.

### 1.3.1

- Fixed failing unit test case
- Updated mongodb driver version

### 1.3.0

- Added support for the new node.js 2.0.x native MongoDB driver
- Write Locks now clear the `write_req` flag when released so that chained writes won't block all readers for long periods of time.
- Updated unit test dependencies

### 1.2.4

- Updated version test to recognize mongodb 3.0 as supporting mongo 2.6 queries

### 1.2.3

- Fixed issue #3, failing unit tests under Mongodb 2.4.x, et al.

### 1.2.2

- Fixed issue #2, a bug that blocked all read locks when a program aborts with an outstanding write lock request, under MongoDB 2.6 only. Thanks to @cearl for reporting.

### 1.2.1

- Fixed errors stemming from improper checking of the mongo error code in an emitted error object.
- Ensure that lockExpiration >= pollingInterval, or expirations may become instantaneous

### 1.2.0

- Introduced independant code paths depending on whether a lock collection is hosted on a MongoDB 2.4 or 2.6+ server. Use of one path or the other is transparent to the user.
- The benefits for MongoDB 2.6 first introduced in v1.1.0 are now back. Support for Mongo 2.4 remains as it was prior to v1.1.0. Both server version use the same gridfs-locks API and have the same functionality, but the MongoDB 2.6 code is simpler and should be more performant, mostly through a reduction in the number of queries used, especially under heavy locking load.

### 1.1.2

- Revert completely to use of MongoDB 2.4.x only update modifiers to maintain compatibility with mongo 2.4.x
- The more efficient MongoDB 2.6 version lives in the mongodb_2.6 branch for now until if can be cleanly included conditionally

### 1.1.1

- Revert from use of MongoDB 2.6 only $currentDate update modifier to maintain compatibility with mongo 2.4.x

### 1.1.0

- Refactoring of mongo queries to make many lock operations significantly faster
- Fixed an issue when multiple read lock holders hold locks with different expiration time lengths, and a lock with a shorter expiration renews and overwrites the later expiring lock's expiration time in the DB.

### 1.0.3

- Fixed typos in README.md code snippets

### 1.0.2

- Updated README.md code blocks to correct formatting glitches on npmjs.org

### 1.0.1

- Fixed issue when multiple simultaneous readers with different lockExpiration values could cause a reader lock to expire prematurely

### 1.0.0

- gridfs-locks now exclusively uses an event-emitter interface. See Readme for more information.

### 0.0.6

- Documentation fixes
- Removed console.log()

### 0.0.5

- Added 60 Unit Tests
- Method Parameters are now extensively validated
- Callback is now optional for Lock.releaseLock(); throws on error when no callback.
- Testing hooks added to obtainWriteLock()

### 0.0.1 - 0.0.4

Initial revision and documentation fixes.
