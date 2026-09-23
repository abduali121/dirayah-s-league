// تاريخ ذكي مشترك للتصريحات والصور: دقائق/ساعات للمحتوى الطازج، ثم اليوم/أمس/قبل
// N أيام، وإلا (أسبوع فأكثر) التاريخ الفعلي بالميلادي — عشان "قبل 12 يوم" ما يبقى
// مبهم على محتوى قديم شوي.
function timeAgo(dateStr){
  const date = new Date(dateStr);
  const diffMin = Math.max(1, Math.round((Date.now() - date.getTime()) / 60000));
  if(diffMin < 60) return `قبل ${diffMin} د`;
  const diffHr = Math.round(diffMin / 60);
  if(diffHr < 24) return `قبل ${diffHr} س`;

  const startOfDay = d => new Date(d.getFullYear(), d.getMonth(), d.getDate());
  const diffDays = Math.round((startOfDay(new Date()) - startOfDay(date)) / 86400000);
  if(diffDays <= 1) return "أمس";
  if(diffDays === 2) return "قبل يومين";
  if(diffDays < 7) return `قبل ${diffDays} أيام`;
  return date.toLocaleDateString("ar", { day: "numeric", month: "long", calendar: "gregory" });
}
