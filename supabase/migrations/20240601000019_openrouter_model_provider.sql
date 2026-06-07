-- Allow users to route Hermes through OpenRouter's model catalog.

alter type agent_model_provider add value if not exists 'openrouter';
