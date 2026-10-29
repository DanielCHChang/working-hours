begin;
select set_config('request.jwt.claim.sub',(select id::text from auth.users limit 1),true);
set local role authenticated;
do $$
declare r jsonb:='{"id":"qa-wh-rollback","order":"TEST-ROLLBACK","quantity":"","completed":"2","operator":"驗證員","date":"2026-10-29","start":"23:30","end":"00:30","summary":"交易回滾測試","notes":""}';v integer;blocked boolean:=false;
begin
perform public.wh_save(r,null);
if(select "calculatedMinutes" from public.wh_records where id='qa-wh-rollback')<>60 then raise exception 'duration failed';end if;
select version into v from public.wh_records where id='qa-wh-rollback';
perform public.wh_save(r||'{"notes":"修改成功"}'::jsonb,v);
if(select notes from public.wh_records where id='qa-wh-rollback')<>'修改成功' then raise exception 'update failed';end if;
begin perform public.wh_save(r,v);exception when others then blocked:=true;end;
if not blocked then raise exception 'conflict failed';end if;
select version into v from public.wh_records where id='qa-wh-rollback';
perform public.wh_delete('qa-wh-rollback',v);
if exists(select 1 from public.wh_records where id='qa-wh-rollback' and deleted_at is null) then raise exception 'delete failed';end if;
if public.wh_import('qa-rollback',jsonb_build_array(r))<>0 then raise exception 'resurrection failed';end if;
if public.wh_import('qa-rollback',jsonb_build_array(r))<>0 then raise exception 'dedupe failed';end if;
end;$$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000099',true);
do $$ begin if exists(select 1 from public.wh_records) or exists(select 1 from public.wh_seed_rows) then raise exception 'RLS isolation failed';end if;end;$$;
reset role;
select 'PASS: CRUD, overnight calculation, stale versions, tombstones, idempotency, isolation' as verification,not has_table_privilege('anon','public.wh_records','select') as anon_denied,not has_function_privilege('anon','public.wh_save(jsonb,integer)','execute') as anon_write_denied;
rollback;
