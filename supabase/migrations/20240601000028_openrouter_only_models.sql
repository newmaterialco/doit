-- Beta: Hermes model selection is OpenRouter-only. Reset legacy direct-provider
-- choices and any locked premium slugs to the default selectable model.

update agent_model_settings
set provider = 'openrouter',
    model = 'google/gemini-3.1-flash-lite',
    apply_status = 'pending',
    apply_error = null
where provider in ('openai', 'anthropic');

update agent_model_settings
set provider = 'openrouter',
    model = 'google/gemini-3.1-flash-lite',
    apply_status = 'pending',
    apply_error = null
where model in (
    'anthropic/claude-sonnet-4-6',
    'anthropic/claude-opus-4',
    'openai/gpt-5.4',
    'openai/gpt-5.5',
    'gpt-5.5',
    'gpt-5.4',
    'gpt-5.4-mini',
    'gpt-4.1-mini',
    'gpt-4.1',
    'claude-sonnet-4-6',
    'claude-opus-4'
);
