# GenevaDrive Manual Style Guide

This guide crystallizes the writing style for the GenevaDrive manual. The manual is written for **humans first, LLMs second** - meaning clarity, narrative flow, and context take priority over structured extraction.

## Voice and Tone

**Use first person plural ("we")** to create partnership with the reader. The manual should feel like a knowledgeable colleague explaining the system, not a reference document dictating rules.

- Write: "We chose to make GenevaDrive transactionless inside steps because..."
- Avoid: "GenevaDrive is transactionless inside steps."

**Be conversational but precise.** Technical accuracy matters, but dry prose distances the reader. The occasional direct address ("you") keeps engagement high.

- Write: "You will almost never have the same `self` between steps."
- Avoid: "The same instance is not guaranteed between steps."

**Confidence without condescension.** Assume the reader is a competent Rails developer who lacks context about durable workflows, not someone who needs Ruby syntax explained.

## Structure and Flow

**Problem before solution.** Every section should establish *why* before *how*. Readers need to understand the problem space to appreciate the design decisions.

```
# Good section flow
1. Here's the problem you face
2. Here are the existing approaches and their limitations
3. Here's how GenevaDrive addresses this
4. Here's how to use it
```

**Progressive complexity.** Start each topic with the simplest case, then layer on complexity. A reader who needs only the basics can stop early; one who needs depth continues reading.

**Self-contained sections.** Each major section should be readable in isolation. Avoid forward references like "as we'll see later" - either explain it now or link to the section.

## Code Examples

**Real business domains.** Use examples from actual business scenarios:
- User onboarding workflows
- Payment processing
- Data erasure for GDPR
- Subscription management
- Document processing

Avoid: `FooWorkflow`, `do_something`, generic placeholder names.

**Complete and runnable.** Every code example should work if pasted into a Rails app. Include the class definition, don't show fragments that require mental reconstruction.

```ruby
# Good: Complete example
class PaymentWorkflow < GenevaDrive::Workflow
  step :initiate_payment do
    PaymentGateway.charge(hero)
  end
end

# Bad: Fragment
step :initiate_payment do
  PaymentGateway.charge(hero)
end
```

**Comments explain the non-obvious.** Don't comment what the code does literally. Comment *why* or *what's special* about this line.

```ruby
# Good
step :confirm_payment, wait: 30.seconds do
  # Poll repeatedly - external system may take time to confirm
  reattempt!(wait: 30.seconds) unless payment_confirmed?
end

# Bad
step :confirm_payment, wait: 30.seconds do
  # Wait 30 seconds then check if payment is confirmed
  reattempt!(wait: 30.seconds) unless payment_confirmed?
end
```

## Explanatory Patterns

**"Imagine you have..."** for scenario setup. This phrase signals a concrete example is coming and helps readers map abstract concepts to their own codebases.

**Bullet points for constraints and lists.** When listing properties, guarantees, or requirements, use bullets. Prose buries important details; bullets make them scannable.

**Short paragraphs.** Two to four sentences maximum. Technical documentation is not an essay - white space aids comprehension.

## Callouts

Use GitHub-flavored callouts for important asides:

- `> [!TIP]` - Helpful shortcuts or best practices
- `> [!IMPORTANT]` - Critical information that affects correctness
- `> [!WARNING]` - Common mistakes or pitfalls
- `> [!NOTE]` - Additional context that clarifies but isn't essential

Don't overuse callouts. More than two per section dilutes their impact.

## Diagrams

Use Mermaid for state machines and flow diagrams. Keep them simple - if a diagram needs extensive explanation, simplify it or split into multiple diagrams.

## What to Avoid

**Don't borrow from stepper_motor.** The GenevaDrive manual must use original phrasing, original examples, and original explanations. The concepts overlap, but the expression must be distinct.

**Don't over-explain Rails.** Assume familiarity with ActiveRecord, ActiveJob, migrations, and standard Rails patterns.

**Don't document internals.** The manual covers usage, not implementation. If something is `@api private`, it doesn't belong in the manual.

**Don't use time estimates.** Don't say "this takes a few minutes" or "this is a quick fix." Time is relative; focus on steps.

**Don't hedge excessively.** "Generally," "typically," "in most cases" - these weaken prose. If something is true, state it. If there are exceptions, enumerate them.

## Terminology

| Term | Usage |
|------|-------|
| Workflow | The durable process, subclass of `GenevaDrive::Workflow` |
| Step | A unit of work within a workflow |
| Hero | The record the workflow operates on (user, payment, etc.) |
| Step Execution | A single attempt to perform a step (idempotency key) |
| Flow control | The DSL methods: `cancel!`, `pause!`, `reattempt!`, `skip!`, `finished!` |

Use these terms consistently. Don't alternate between "workflow" and "process" or "hero" and "target record."

## Length Guidelines

- Section introduction: 2-3 paragraphs max
- Code example explanation: 1-2 paragraphs before, 1 paragraph after
- Subsections: Complete a topic in under 500 words where possible
- The full manual: Should be readable in one sitting (30-45 minutes)
