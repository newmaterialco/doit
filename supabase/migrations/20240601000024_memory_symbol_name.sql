-- Passbook memory row icon: SF Symbol name chosen by the agent or a keyword heuristic.
alter table memories
    add column symbol_name text check (
        symbol_name is null or char_length(symbol_name) between 1 and 80
    );

comment on column memories.symbol_name is
    'SF Symbol name for Passbook avatar (e.g. airplane, person.crop.circle).';
