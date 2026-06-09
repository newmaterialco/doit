-- Task organization metadata.
--
-- Completed tasks can be browsed by broad topic, optional named collection,
-- and a user-controlled star. These fields live on `todos` so existing RLS,
-- REST refreshes, and Supabase Realtime row updates continue to work without
-- a second client-side cache.

alter table todos
    add column if not exists is_starred boolean not null default false,
    add column if not exists topic text
        check (
            topic is null
            or topic in (
                'communication',
                'scheduling',
                'research',
                'documents',
                'coding',
                'finance',
                'shopping',
                'travel',
                'personal',
                'work',
                'other'
            )
        ),
    add column if not exists collection_name text
        check (
            collection_name is null
            or char_length(collection_name) between 1 and 80
        );

create index if not exists todos_user_topic_done_idx
    on todos (user_id, topic, updated_at desc)
    where status = 'done';

create index if not exists todos_user_collection_done_idx
    on todos (user_id, collection_name, updated_at desc)
    where status = 'done' and collection_name is not null;

create index if not exists todos_user_starred_done_idx
    on todos (user_id, updated_at desc)
    where status = 'done' and is_starred = true;

comment on column todos.is_starred is
    'User-controlled flag for completed tasks the user wants to keep handy.';
comment on column todos.topic is
    'Broad task category assigned during preparation for completed activity browsing.';
comment on column todos.collection_name is
    'Optional durable named grouping such as a project, company, client, or event.';
