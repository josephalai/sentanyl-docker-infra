# Variable for filename for store running procees id
PID_FILE = /tmp/my-app.pid
# We can use such syntax to get main.go and other root Go files.
GO_FILES = $(wildcard cmd/*.go)

# Start task performs "go run main.go" command and writes it's process id to PID_FILE.
start:
	go run $(GO_FILES) & echo $$! > $(PID_FILE)

# Stop task will kill process by ID stored in PID_FILE (and all child processes by pstree).  
stop:
	-kill `pstree -p \`cat $(PID)\` | tr "\n" " " |sed "s/[^0-9]/ /g" |sed "s/\s\s*/ /g"` 
  
# Before task will only prints message. Actually, it is not necessary. You can remove it, if you want.
before:
	@echo "STOPED my-app" && printf '%*s\n' "40" '' | tr ' ' -
  
# Restart task will execute stop, before and start tasks in strict order and prints message. 
restart: stop before start
	@echo "STARTED my-app" && printf '%*s\n' "40" '' | tr ' ' -
  
# Serve task runs the application directly (legacy fswatch removed).
serve: start

# Run unit tests (no MongoDB required)
test-unit:
	cd core-service && go test -v -timeout 60s ./scripting/...

# Run all tests
test: test-unit

# Run the comprehensive live test script against a running local server
live-test:
	bash sentanyl-live-test.sh

# .PHONY is used for reserving tasks words
.PHONY: start before stop restart serve test test-unit live-test
