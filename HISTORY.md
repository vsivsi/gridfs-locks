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
