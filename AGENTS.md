# Claude Code Instructions

## Git Commits

**Do not commit changes automatically.** Wait for the user to review changes and explicitly ask for a commit. Only create commits when the user requests it.

## Ruby Style

**Use flat module syntax.** Define classes and modules with the full namespace on the first line to minimize indentation:

```ruby
# Good - flat syntax
class GenevaDrive::Workflow < ActiveRecord::Base
  def perform
    # ...
  end
end

module GenevaDrive::FlowControl
  def cancel!
    # ...
  end
end

# Bad - nested syntax
module GenevaDrive
  class Workflow < ActiveRecord::Base
    def perform
      # ...
    end
  end
end
```

**Exception:** Rails generators must use nested syntax because they are loaded directly by Rails before autoload runs.

**Do not reload inside `with_lock` blocks.** Rails' `with_lock` automatically reloads the record before yielding. If you need to verify a value hasn't changed, check it inside the block (after the automatic reload):

```ruby
# Good - with_lock reloads automatically
def pause!
  with_lock do
    raise InvalidStateError unless state == "ready"  # Check after automatic reload
    update!(state: "paused")
  end
end

# Bad - redundant reload
def pause!
  with_lock do
    reload  # Unnecessary - with_lock already reloaded
    raise InvalidStateError unless state == "ready"
    update!(state: "paused")
  end
end
```
