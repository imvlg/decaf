insert into public.de_caf_invites (code_hash, active)
values (
  encode(
    extensions.digest(
      convert_to('2676f5ef2073bcc1d49c6a5a3d790d9cfebb36223311816f1fb466bf49dce3d4', 'UTF8'),
      'sha256'
    ),
    'hex'
  ),
  true
)
on conflict (code_hash) do update set active = true;

create or replace function public.de_caf_join(
  p_invite_code text,
  p_display_name text default null
)
returns table (display_name text)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
set row_security = off
as $$
declare
  clean_name text := nullif(trim(coalesce(p_display_name, '')), '');
  invite_hash text;
  existing_name text;
begin
  if auth.uid() is null then
    raise exception 'Sign in is required';
  end if;

  if clean_name is not null and char_length(clean_name) > 32 then
    raise exception 'Name must be 32 characters or fewer';
  end if;

  select m.display_name
    into existing_name
    from public.de_caf_members as m
   where m.user_id = auth.uid();

  if found then
    if clean_name is not null then
      update public.de_caf_members as m
         set display_name = clean_name
       where m.user_id = auth.uid()
       returning m.display_name into existing_name;
    end if;
    return query select existing_name;
    return;
  end if;

  invite_hash := encode(
    extensions.digest(convert_to(trim(coalesce(p_invite_code, '')), 'UTF8'), 'sha256'),
    'hex'
  );

  if not exists (
    select 1
      from public.de_caf_invites as i
     where i.code_hash = invite_hash
       and i.active = true
  ) then
    raise exception 'Invite link is invalid or disabled';
  end if;

  insert into public.de_caf_members (user_id, display_name)
  values (auth.uid(), clean_name);

  return query
    select m.display_name
      from public.de_caf_members as m
     where m.user_id = auth.uid();
end;
$$;

revoke all on function public.de_caf_join(text, text) from public, anon;
grant execute on function public.de_caf_join(text, text) to authenticated;
