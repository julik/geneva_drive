* **NEVER add foreign key constraints in the SQLite migration flavours** - Because we have to be compatible with SQLite and not destroy data, and adding foreign keys causes table recreation which can lead to data loss. See: https://kyrylo.org/software/2025/09/27/a-mere-add-foreign-key-can-wipe-out-your-whole-rails-sqlite-production-table.html. If referential integrity is needed and you need to do ALTER TABLE that will cause a table recreation, find a way to do it via an atomic table swap, or stop and ask the human operator.
* **Avoid migrations that cause SQLite table rewrites** - Operations like `change_column_null`, `change_column_default`, `change_column` trigger full table recreation in SQLite (create new table, copy data, drop old, rename). This can corrupt foreign key references and cause data loss. Instead, enforce constraints at the model level (validations, `belongs_to` with `optional: true/false`). If DB constraints are needed and you need to do ALTER TABLE that will cause a table recreation, find a way to do it via an atomic table swap, or stop and ask the human operator.

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
