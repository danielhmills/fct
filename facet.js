function link_change (prop)
{
  var a = $('map_link');
  if (a)
    a.href = a.href + '&location-prop=' + escape (prop);
}

function fct_nav_to (url)
{
  document.location = url;
}