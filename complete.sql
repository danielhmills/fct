-- URI completion 

create procedure 
num_str (in n int)
{
  declare s varchar;

  s := '1234';

  s[0] := bit_shift (n, -24);
  s[1] := bit_shift (n, -16);
  s[2] := bit_shift (n, -8);
  s[3] := n;

  return s;
}


create procedure 
str_inc (in str varchar, in pref int := 0)
{
  -- increment by one for range cmp
  declare len int;
  len := length (str);
 carry:
  if (pref = len)
    return subseq (str, 0, pref) || '\377\377\377\377';
  str [len - 1] := str[len - 1] + 1;
    if (str[len - 1] = 0)
      {
      len := len - 1;
	goto carry;
      }
    return str;
}


--create procedure split (in str varchar)
--{
--  declare pref, name varchar;
--  result_names (pref, name);
--  pref := iri_split (str, name, 1);
--  result (pref, subseq (name, 4));
--}


create procedure 
cmp_find_iri (in str varchar, in no_name int := 0)
{
  /* We look for iris, assuming the full ns is in the name  */

  declare pref, name varchar;
  declare id, inx int;
  declare iris any;

  if (no_name)
    {
      pref := str;
      name := '1111';
    }
  else 
    pref := iri_split (str, name, 1);

  id := (select rp_id 
           from rdf_prefix 
           where rp_name = pref);

  if (id is null)
    return null;

  name[0] := bit_shift (id, -24);
  name[1] := bit_shift (id, -16);
  name[2] := bit_shift (id, -8);
  name[3] := id;


  if (no_name)
    {
      iris :=  (select vector_agg (ri_name) 
                from (select top 20 ri_name 
                        from rdf_iri 
                        where ri_name >= name and 
                              ri_name < num_str (id + 1)) ir);

      if (length (iris) < 20 and length (iris) > 1)
        iris := (select vector_agg (ri_name) 
                 from (select ri_name 
                         from rdf_iri 
                         where ri_name >= name and 
                               ri_name < num_str (id + 1)
                         order by iri_rank (ri_id) desc) ir);
    }
  else 
    {
      iris :=  (select vector_agg (ri_name) 
                  from (select top 20 ri_name 
                          from rdf_iri 
                          where ri_name >= name and 
                                ri_name < str_inc (name, 4)) ir);

      if (length (iris) < 20 and length (iris) > 1)
        iris := (select vector_agg (ri_name) 
                 from (select ri_name 
                         from rdf_iri 
                         where ri_name >= name and 
                               ri_name < str_inc (name, 4) 
                         order by iri_rank (ri_id) desc) ir);
    }

  for (inx := 0; inx < length (iris); inx := inx + 1)
    {
      iris[inx] := pref || subseq (iris[inx], 4);
    }

  return iris;
}

create procedure 
cmp_find_ns (in str varchar)
{
  declare nss any;

  nss := (select vector_agg (rp_name) 
            from (select top 20 rp_name 
                    from rdf_prefix 
                    where rp_name >= str and 
                          rp_name < str_inc (str)) ns);

  return nss;
}



create procedure 
cmp_with_ns (in str varchar)
{
  declare pref_str varchar;
  declare col int;

  col := position (':', str);

  if (col = 0)
    return null;

  pref_str := (select ns_url 
                 from SYS_XML_PERSISTENT_NS_DECL 
                 where ns_prefix = subseq (str, 0, col - 1));
  if (pref_str is null)
    return null;

  str := pref_str || subseq (str, col);
  return str;
}


create procedure 
cmp_uri (in str varchar)
{
  declare with_ns varchar;
  declare nss, iris any;

--  dbg_printf ('cmp_uri\n');

  if (strstr (str, '://') is null)
    {
      with_ns := cmp_with_ns (str);

      if (with_ns is not null)
	return cmp_find_iri (with_ns);

      -- no protocol and no known prefix
	str := 'http://' || str;
    }

  nss := cmp_find_ns (str);

--  dbg_obj_print ('ns with ', str, ' = ', nss);

  if (length (nss) = 0)
    return cmp_find_iri (str);

  iris := cmp_find_iri (nss[0], 1);

  return vector (iris, nss);
}

create procedure 
urilbl_ac_ruin_label (in lbl varchar)
{
  return left (upper (regexp_replace (lbl, '[''",.]', '', 1, null)), 
               _min (length (lbl), 50));
}
;

create procedure
urilbl_ac_init_db () {

  set isolation = 'committed';
  for (sparql 
        define output:valmode 'LONG' 
        define input:inference 'facets' 
        select ?s ?o (lang(?o)) as ?lng where { ?s virtrdf:label ?o }) do 
    {
      insert soft 
        urilbl_complete_lookup (ull_label_lang, ull_label_ruined, ull_iid, ull_label) 
        values (lng, urilbl_ac_ruin_label (o), s, o);
      commit work;
    }
}
;

-- Originally from rdf_mappers/rdfdesc.sql
-- Determine q of given lang based on value of Accept-Language hdr

create procedure 
cmp_get_lang_by_q (in accept varchar, in lang varchar)
{
  declare format, itm, q varchar;
  declare arr any;
  declare i, l int;

  arr := split_and_decode (accept, 0, '\0\0,;');
  q := 0;
  l := length (arr);
  format := null;
  for (i := 0; i < l; i := i + 2)
    {
      declare tmp any;
      itm := trim(arr[i]);
      if (itm = lang)
	{
	  q := arr[i+1];
	  if (q is null)
	    q := 1.0;
	  else
	    {
	      tmp := split_and_decode (q, 0, '\0\0=');
	      if (length (tmp) = 2)
		q := atof (tmp[1]);
	      else
		q := 1.0;
	    }
	  goto ret;
	}
    }
  ret:
  if (q = 0 and lang = 'en')
    q := 0.002;
  if (q = 0 and not length (lang))
    q := 0.001;
  return q;
}
;

create procedure
cmp_label (in lbl_str varchar, in langs varchar)
{
  declare res any;
  declare q,best_q float;
  declare cur_iid any;
  declare cur_lbl varchar;
  declare n integer;

  res := vector();

--  dbg_printf ('cmp_label');
  cur_iid := null;
  best_q := 0;

  for (select ull_label_lang, ull_label, ull_iid
         from urilbl_complete_lookup 
         where ull_label_ruined like urilbl_ac_ruin_label (lbl_str) || '%') do
    {
      if (cur_iid is not null and ull_iid <> cur_iid)
        {
          res := vector_concat (res, vector (cur_lbl, id_to_iri(cur_iid)));
          n := n + 1;
          if (n >= 50) goto done;
          best_q := 0;
	}

      cur_iid := ull_iid;
      q := cmp_get_lang_by_q (langs, ull_label_lang);

      if (q >= best_q) 
        {
          best_q := q;
          cur_lbl := ull_label;
	}
    }
  res := vector_concat (res, vector (cur_lbl, id_to_iri (cur_iid)));
 done:;
  return res;
}

