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
