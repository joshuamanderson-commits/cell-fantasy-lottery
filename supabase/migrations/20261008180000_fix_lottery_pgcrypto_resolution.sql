-- Qualify pgcrypto calls because this RPC deliberately uses an empty search_path.
-- No table changes or lottery selection changes.
CREATE OR REPLACE FUNCTION public.draw_fantasy_lottery_pick(p_season_id uuid)
 RETURNS TABLE(participant_id uuid, display_name text, pick_number integer, balls_at_draw integer, chance_at_draw numeric, top_five_protection_applied boolean, remaining_count integer, pool_size integer)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_pick_number integer;
  v_remaining_count integer;
  v_pool_size integer;
  v_selected_id uuid;
  v_selected_name text;
  v_selected_balls integer;
  v_top_five boolean := false;
  v_random bigint;
  v_target integer;
  v_running integer := 0;
  v_rec record;
begin
  if v_uid is null or not exists (
    select 1
    from public.user_roles ur
    where ur.user_id = v_uid
      and ur.role = 'admin'
  ) then
    raise exception 'Not authorized';
  end if;

  if not exists (
    select 1
    from public.fantasy_lottery_seasons s
    where s.id = p_season_id
      and s.draft_status in ('in_progress','not_started')
  ) then
    raise exception 'Draft is not available for drawing';
  end if;

  select count(*) + 1
    into v_pick_number
  from public.fantasy_lottery_draft_results d
  where d.season_id = p_season_id;

  select count(*)
    into v_remaining_count
  from public.fantasy_lottery_participants p
  where p.season_id = p_season_id
    and p.is_active = true
    and not exists (
      select 1
      from public.fantasy_lottery_draft_results d
      where d.season_id = p_season_id
        and d.participant_id = p.id
    );

  if v_remaining_count = 0 then
    raise exception 'No owners remain';
  end if;

  select coalesce(sum(greatest(0, p.base_balls + p.purchased_balls + p.bonus_balls)),0)
    into v_pool_size
  from public.fantasy_lottery_participants p
  where p.season_id = p_season_id
    and p.is_active = true
    and not exists (
      select 1
      from public.fantasy_lottery_draft_results d
      where d.season_id = p_season_id
        and d.participant_id = p.id
    );

  if v_pool_size <= 0 then
    raise exception 'No lottery balls remain';
  end if;

  if v_remaining_count = 1 then
    select p.id, p.display_name,
           greatest(0, p.base_balls + p.purchased_balls + p.bonus_balls)
      into v_selected_id, v_selected_name, v_selected_balls
    from public.fantasy_lottery_participants p
    where p.season_id = p_season_id
      and p.is_active = true
      and not exists (
        select 1
        from public.fantasy_lottery_draft_results d
        where d.season_id = p_season_id
          and d.participant_id = p.id
      )
    limit 1;
  elsif v_pick_number = 5 then
    select p.id, p.display_name,
           greatest(0, p.base_balls + p.purchased_balls + p.bonus_balls)
      into v_selected_id, v_selected_name, v_selected_balls
    from public.fantasy_lottery_participants p
    where p.season_id = p_season_id
      and p.is_active = true
      and p.is_first_place = true
      and not exists (
        select 1
        from public.fantasy_lottery_draft_results d
        where d.season_id = p_season_id
          and d.participant_id = p.id
      )
    limit 1;

    if v_selected_id is not null then
      v_top_five := true;
    end if;
  end if;

  if v_selected_id is null then
    v_random :=
      (get_byte(extensions.gen_random_bytes(4),0)::bigint << 24) +
      (get_byte(extensions.gen_random_bytes(4),0)::bigint << 16) +
      (get_byte(extensions.gen_random_bytes(4),0)::bigint << 8) +
      get_byte(extensions.gen_random_bytes(4),0)::bigint;
    v_target := (v_random % v_pool_size) + 1;

    for v_rec in
      select p.id, p.display_name,
             greatest(0, p.base_balls + p.purchased_balls + p.bonus_balls) as balls
      from public.fantasy_lottery_participants p
      where p.season_id = p_season_id
        and p.is_active = true
        and not exists (
          select 1
          from public.fantasy_lottery_draft_results d
          where d.season_id = p_season_id
            and d.participant_id = p.id
        )
      order by p.id
    loop
      v_running := v_running + v_rec.balls;
      if v_target <= v_running then
        v_selected_id := v_rec.id;
        v_selected_name := v_rec.display_name;
        v_selected_balls := v_rec.balls;
        exit;
      end if;
    end loop;
  end if;

  if v_selected_id is null then
    raise exception 'Unable to select owner';
  end if;

  insert into public.fantasy_lottery_draft_results (
    season_id,
    participant_id,
    pick_number,
    balls_at_draw,
    chance_at_draw,
    top_five_protection_applied
  )
  values (
    p_season_id,
    v_selected_id,
    v_pick_number,
    v_selected_balls,
    case when v_pool_size > 0 then (v_selected_balls::numeric / v_pool_size::numeric) * 100 else 0 end,
    v_top_five
  );

  update public.fantasy_lottery_seasons
  set draft_status = case when v_remaining_count = 1 then 'completed' else 'in_progress' end,
      draft_started_at = coalesce(draft_started_at, now()),
      draft_completed_at = case when v_remaining_count = 1 then now() else draft_completed_at end,
      updated_at = now()
  where id = p_season_id;

  return query
  select
    v_selected_id,
    v_selected_name,
    v_pick_number,
    v_selected_balls,
    case when v_pool_size > 0 then (v_selected_balls::numeric / v_pool_size::numeric) * 100 else 0 end,
    v_top_five,
    v_remaining_count,
    v_pool_size;
end;
$function$
;
