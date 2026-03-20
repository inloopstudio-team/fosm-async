# FOSM-Async

Fiber-based asynchronous transitions for [FOSM-Rails](https://github.com/inloopstudio/fosm-rails).

[![Ruby](https://img.shields.io/badge/ruby-3.4%2B-red.svg)](https://www.ruby-lang.org/)
[![Rails](https://img.shields.io/badge/rails-8.0%2B-blue.svg)](https://rubyonrails.org/)

## Overview

`fosm-async` extends FOSM with fiber-based concurrent transition processing. Using Ruby 3.4+ fibers via the [`async`](https://github.com/socketry/async) gem, this extension enables:

- **Concurrent transition execution** — Process thousands of transitions with a single thread
- **Parallel guard evaluation** — Run multiple guards simultaneously, reducing latency
- **Fiber-based buffering** — Non-blocking transition log writes with backpressure
- **Structured bulk operations** — Safe concurrent processing with supervision

## Installation

Add to your Gemfile:

```ruby
gem "fosm-rails", "~> 0.2"
gem "fosm-async", "~> 0.1"
```

Install:

```bash
bundle install
```

## Quick Start

```ruby
class Invoice < ApplicationRecord
  include Fosm::Lifecycle
  include Fosm::Async::LifecycleAsync  # Add async capabilities
  
  lifecycle do
    state :draft, initial: true
    state :sent
    state :paid, terminal: true
    
    event :send_invoice, from: :draft, to: :sent
    event :pay, from: :sent, to: :paid
  end
end
```

### Fire Async

```ruby
# Process 100 invoices concurrently with 1 thread
Async do
  invoices.each do |invoice|
    Async do
      result = invoice.fire_async!(:send_invoice, actor: current_user)
      puts "Invoice #{invoice.id}: #{result[:success] ? 'sent' : result[:error]}"
    end
  end
end
```

## Features

### 1. Async Transitions (`fire_async!`)

Run transitions in fibers that yield during I/O operations:

```ruby
result = invoice.fire_async!(:send_invoice, actor: user)
# => { success: true, state: "sent" }
# or { success: false, error: "GuardFailed", message: "..." }
```

Benefits:
- Side effects (HTTP calls, emails) don't block other transitions
- Single thread handles thousands of concurrent operations
- No thread pool exhaustion under load

### 2. Concurrent Guard Evaluation

Run guards in parallel when inside an async context:

```ruby
guard :credit_check, on: :approve do |record|
  # This runs in parallel with other guards
  CreditService.check(record.customer_id).approved?
end

guard :fraud_check, on: :approve do |record|
  # This runs in parallel with credit_check
  FraudService.clear?(record.ip_address)
end
```

3 guards × 100ms each = 300ms sequential, ~100ms concurrent.

### 3. Fiber-Based Transition Buffer

Replace the thread-based buffer with fiber-based scheduling:

```ruby
# config/initializers/fosm.rb
Fosm.configure do |config|
  config.transition_log_strategy = :fiber_buffered  # Use async buffer
end
```

Benefits:
- No dedicated thread (runs in main async loop)
- Dynamic batch sizing based on load
- Built-in backpressure prevents memory exhaustion

### 4. Bulk Operations

Process collections with bounded concurrency:

```ruby
# Process up to 10 invoices concurrently
results = Fosm::Async::BulkOperations.fire_all!(
  invoices,
  :send_invoice,
  actor: current_user,
  max_concurrent: 10
)

# => { 
#   invoice_id_1: { success: true },
#   invoice_id_2: { success: false, error: "GuardFailed", message: "..." },
#   ...
# }
```

Features:
- Bounded concurrency (prevents DB connection pool exhaustion)
- Isolated failures (one failure doesn't stop others)
- Structured supervision (parent monitors all children)

## API Reference

### `LifecycleAsync`

Mixin that adds async capabilities to FOSM models.

#### `fire_async!(event_name, actor: nil, metadata: {})`

Fire a transition inside a fiber.

**Parameters:**
- `event_name` (Symbol/String) — Event to fire
- `actor` (Object/Symbol/nil) — Who/what is firing the event
- `metadata` (Hash) — Optional metadata for transition log

**Returns:** Hash with `success`, `state`, and optionally `error`/`message`

### `GuardRunner`

Concurrent guard evaluation using `Async::Barrier`.

```ruby
Fosm::Async::GuardRunner.evaluate_concurrently(
  guard_definitions,
  record,
  timeout: 5
)
```

### `TransitionBufferFiber`

Fiber-based transition log buffering.

```ruby
Fosm::Async::TransitionBufferFiber.push(log_entry)
Fosm::Async::TransitionBufferFiber.start_flusher!  # Start background fiber
```

### `BulkOperations`

Structured concurrency for bulk transition processing.

```ruby
# Partial success (each record independent)
Fosm::Async::BulkOperations.fire_all!(
  records,
  event_name,
  actor:,
  max_concurrent: 10
)

# All-or-nothing (experimental)
Fosm::Async::BulkOperations.fire_all_or_nothing!(
  records,
  event_name,
  actor:
)
```

## Configuration

```ruby
# config/initializers/fosm_async.rb

# Enable fiber scheduler at boot
Rails.application.config.after_initialize do
  Fosm::Async::TransitionBufferFiber.start_flusher! if 
    Fosm.config.transition_log_strategy == :fiber_buffered
end
```

## Testing

Run the test suite:

```bash
bundle exec rake test
```

Or specific test types:

```bash
bundle exec rake litmus   # Critical path tests
bundle exec rake smoke    # Quick feature checks
bundle exec rake coverage # With coverage report
```

## Requirements

- Ruby 3.4+ (for Fiber::Scheduler support)
- Rails 8.0+
- FOSM-Rails 0.2+
- `async` gem 2.0+

## Architecture

```
┌─────────────────────────────────────────────┐
│             Main Thread                     │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐      │
│  │ Fiber 1 │  │ Fiber 2 │  │ Fiber 3 │ ...  │
│  │ (inv 1) │  │ (inv 2) │  │ (inv 3) │      │
│  └────┬────┘  └────┬────┘  └────┬────┘      │
│       │            │            │           │
│       └────────────┴────────────┘           │
│                    │                        │
│            ┌───────┴───────┐                │
│            │ Async Barrier │                │
│            │  (guards)     │                │
│            └───────┬───────┘                │
│                    │                        │
│            ┌───────┴───────┐                │
│            │  Scheduler    │                │
│            │  (I/O yield)  │                │
│            └───────────────┘                │
└─────────────────────────────────────────────┘
```

## License

MIT License. See [LICENSE](../fosm-rails/LICENSE) for details.

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feat/amazing-feature`)
3. Commit your changes (`git commit -am 'feat: add amazing feature'`)
4. Push to the branch (`git push origin feat/amazing-feature`)
5. Open a Pull Request

## Related

- [FOSM-Rails](https://github.com/inloopstudio/fosm-rails) — Core finite object state machine engine
- [FOSM-Temporal](https://github.com/inloopstudio-team/fosm-temporal) — Scheduled auto-transitions
