-- Apply once in the existing CRM Supabase project. No CRM tables are modified.
begin;
create table public.wh_groups (
 user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
 id text not null check(length(id) between 1 and 200),
 order_no text not null check(length(btrim(order_no)) between 1 and 60),
 completed bigint not null check(completed between 0 and 9007199254740991),
 version integer not null default 1,
 primary key(user_id,id)
);
create table public.wh_reports (
 user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
 id text not null check(length(id) between 1 and 200),
 group_id text not null,
 quantity bigint check(quantity between 1 and 9007199254740991),
 operator text not null check(length(btrim(operator)) between 1 and 40),
 work_date date not null,
 start_time time(0), end_time time(0), imported_minutes integer check(imported_minutes>0),
 duration_minutes integer generated always as (case when start_time is not null and end_time is not null then ((extract(epoch from end_time-start_time)::integer+86400)%86400)/60 else imported_minutes end) stored,
 summary text not null check(length(btrim(summary)) between 1 and 500),
 notes text not null default '' check(length(notes)<=1000),
 source text, source_row integer check(source_row>0),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), deleted_at timestamptz,
 primary key(user_id,id), foreign key(user_id,group_id) references public.wh_groups(user_id,id),
 check((start_time is null and end_time is null and imported_minutes is not null) or (start_time is not null and end_time is not null and start_time<>end_time and imported_minutes is null)),
 check(start_time is null or extract(second from start_time)=0),check(end_time is null or extract(second from end_time)=0)
);
create index wh_reports_group_idx on public.wh_reports(user_id,group_id);
create index wh_reports_date_idx on public.wh_reports(user_id,work_date desc,id) where deleted_at is null;
create table public.wh_imports(user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,batch text not null check(length(batch) between 1 and 200),added integer not null,completed_at timestamptz not null default now(),primary key(user_id,batch));
alter table public.wh_groups enable row level security;
alter table public.wh_reports enable row level security;
alter table public.wh_imports enable row level security;
revoke all on public.wh_groups,public.wh_reports,public.wh_imports from public,anon,authenticated;
grant usage on schema public to authenticated;
grant select,insert on public.wh_groups,public.wh_reports,public.wh_imports to authenticated;
grant update(order_no,completed,version) on public.wh_groups to authenticated;
grant update(quantity,operator,work_date,start_time,end_time,imported_minutes,summary,notes,updated_at,deleted_at) on public.wh_reports to authenticated;
create policy wh_group_read on public.wh_groups for select to authenticated using((select auth.uid())=user_id);
create policy wh_group_add on public.wh_groups for insert to authenticated with check((select auth.uid())=user_id);
create policy wh_group_update on public.wh_groups for update to authenticated using((select auth.uid())=user_id) with check((select auth.uid())=user_id);
create policy wh_report_read on public.wh_reports for select to authenticated using((select auth.uid())=user_id);
create policy wh_report_add on public.wh_reports for insert to authenticated with check((select auth.uid())=user_id);
create policy wh_report_update on public.wh_reports for update to authenticated using((select auth.uid())=user_id) with check((select auth.uid())=user_id);
create policy wh_import_read on public.wh_imports for select to authenticated using((select auth.uid())=user_id);
create policy wh_import_add on public.wh_imports for insert to authenticated with check((select auth.uid())=user_id);
create view public.wh_records with(security_invoker=true) as select r.id,g.order_no as "order",coalesce(r.quantity::text,'') as quantity,g.completed::text as completed,r.operator,r.work_date::text as date,coalesce(to_char(r.start_time,'HH24:MI'),'') as start,coalesce(to_char(r.end_time,'HH24:MI'),'') as "end",r.summary,r.notes,r.imported_minutes as "durationMinutes",r.duration_minutes as "calculatedMinutes",r.group_id as "groupId",r.source,r.source_row as "sourceRow",g.version,r.updated_at,r.deleted_at from public.wh_reports r join public.wh_groups g on (g.user_id,g.id)=(r.user_id,r.group_id);
revoke all on public.wh_records from public,anon,authenticated;
grant select on public.wh_records to authenticated;
create function public.wh_save(p_record jsonb,p_version integer default null) returns text language plpgsql security invoker set search_path='' as $$
declare u uuid:=auth.uid(); rid text:=p_record->>'id'; gid text; old public.wh_reports; g public.wh_groups;
begin
 if u is null then raise exception 'Sign in required' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(u::text,71));
 select * into old from public.wh_reports where user_id=u and id=rid;
 if found then
  if old.deleted_at is not null then raise exception '紀錄已刪除，請重新整理。';end if;
  if p_version is null then return rid;end if;
  gid:=old.group_id;
 else
  if p_version is not null then raise exception '紀錄不存在，請重新整理。';end if;
  gid:=coalesce(nullif(p_record->>'groupId',''),rid);
 end if;
 select * into g from public.wh_groups where user_id=u and id=gid for update;
 if found then
  if p_version is not null and g.version<>p_version then raise exception '資料已被其他裝置修改，請取消編輯並重新整理。';end if;
  if old.id is null and (g.order_no<>btrim(p_record->>'order') or g.completed<>(p_record->>'completed')::bigint) then raise exception '同來源的製令與完成數量不一致。';end if;
  update public.wh_groups set order_no=btrim(p_record->>'order'),completed=(p_record->>'completed')::bigint,version=version+1 where user_id=u and id=gid;
 else
  insert into public.wh_groups(user_id,id,order_no,completed) values(u,gid,btrim(p_record->>'order'),(p_record->>'completed')::bigint);
 end if;
 if old.id is null then
  insert into public.wh_reports(user_id,id,group_id,quantity,operator,work_date,start_time,end_time,imported_minutes,summary,notes,source,source_row)
  values(u,rid,gid,nullif(p_record->>'quantity','')::bigint,btrim(p_record->>'operator'),(p_record->>'date')::date,nullif(p_record->>'start','')::time,nullif(p_record->>'end','')::time,case when coalesce(p_record->>'start','')='' then (p_record->>'durationMinutes')::integer end,btrim(p_record->>'summary'),coalesce(p_record->>'notes',''),p_record->>'source',(p_record->>'sourceRow')::integer);
 else
  update public.wh_reports set quantity=nullif(p_record->>'quantity','')::bigint,operator=btrim(p_record->>'operator'),work_date=(p_record->>'date')::date,start_time=nullif(p_record->>'start','')::time,end_time=nullif(p_record->>'end','')::time,imported_minutes=case when coalesce(p_record->>'start','')='' then (p_record->>'durationMinutes')::integer end,summary=btrim(p_record->>'summary'),notes=coalesce(p_record->>'notes',''),updated_at=clock_timestamp() where user_id=u and id=rid;
 end if;
 return rid;
end;$$;
create function public.wh_delete(p_id text,p_version integer) returns void language plpgsql security invoker set search_path='' as $$
declare u uuid:=auth.uid(); r public.wh_reports; v integer;
begin
 if u is null then raise exception 'Sign in required' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended(u::text,71));
 select * into r from public.wh_reports where user_id=u and id=p_id and deleted_at is null;
 if not found then raise exception '紀錄已刪除，請重新整理。';end if;
 select version into v from public.wh_groups where user_id=u and id=r.group_id for update;
 if v is distinct from p_version then raise exception '資料已被其他裝置修改，請重新整理。';end if;
 update public.wh_reports set deleted_at=clock_timestamp(),updated_at=clock_timestamp() where user_id=u and id=p_id;
 update public.wh_groups set version=version+1 where user_id=u and id=r.group_id;
end;$$;
create function public.wh_import(p_batch text,p_rows jsonb) returns integer language plpgsql security invoker set search_path='' as $$
declare u uuid:=auth.uid(); item jsonb; added integer:=0;
begin
 if u is null then raise exception 'Sign in required' using errcode='42501';end if;
 if p_batch is null or length(p_batch) not between 1 and 200 or jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'Invalid import';end if;
 perform pg_advisory_xact_lock(hashtextextended(u::text,71));
 if exists(select 1 from public.wh_imports where user_id=u and batch=p_batch) then return 0;end if;
 for item in select value from jsonb_array_elements(p_rows) loop
  if not exists(select 1 from public.wh_reports where user_id=u and id=item->>'id') then perform public.wh_save(item,null);added:=added+1;end if;
 end loop;
 insert into public.wh_imports(user_id,batch,added) values(u,p_batch,added);
 return added;
end;$$;
revoke all on function public.wh_save(jsonb,integer),public.wh_delete(text,integer),public.wh_import(text,jsonb) from public,anon,authenticated;
grant execute on function public.wh_save(jsonb,integer),public.wh_delete(text,integer),public.wh_import(text,jsonb) to authenticated;
create table public.wh_seed_rows(user_id uuid primary key references auth.users(id) on delete cascade,rows jsonb not null);
alter table public.wh_seed_rows enable row level security;
revoke all on public.wh_seed_rows from public,anon,authenticated;
grant select on public.wh_seed_rows to authenticated;
create policy wh_seed_read on public.wh_seed_rows for select to authenticated using((select auth.uid())=user_id);
notify pgrst,'reload schema';
commit;
