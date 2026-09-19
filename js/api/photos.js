async function listPhotos(limit = 20){
  const { data, error } = await sb
    .from("league_photos")
    .select("*, team:team_id(name, primary_color)")
    .order("created_at", { ascending: false })
    .limit(limit);
  if(error) throw error;
  return data;
}

// يرفع صورة لتخزين Supabase (bucket عام) ويرجع رابطها المباشر
async function uploadPhotoImage(file){
  const ext = file.name.split(".").pop();
  const path = `${crypto.randomUUID()}.${ext}`;
  const { error } = await sb.storage.from("announcement-images").upload(path, file);
  if(error) throw error;
  const { data } = sb.storage.from("announcement-images").getPublicUrl(path);
  return data.publicUrl;
}

async function createPhoto(imageUrl, caption = null, teamId = null){
  const { data, error } = await sb.rpc("create_photo", {
    p_image_url: imageUrl, p_caption: caption, p_team_id: teamId,
  });
  if(error) throw error;
  return data;
}

async function deletePhoto(id){
  const { data, error } = await sb.rpc("delete_photo", { p_photo_id: id });
  if(error) throw error;
  return data;
}

async function deletePhotoImage(imageUrl){
  if(!imageUrl) return;
  const path = imageUrl.split("/announcement-images/").pop();
  if(!path) return;
  await sb.storage.from("announcement-images").remove([path]);
}

// صورة عادية من كابتن — 25 دراية، تُنشر فورًا باسم فريقه بلا حاجة لاعتماد الإدارة
async function submitTeamPhoto(imageUrl, caption = null){
  const { data, error } = await sb.rpc("submit_team_photo", {
    p_image_url: imageUrl, p_caption: caption,
  });
  if(error) throw error;
  return data;
}

// أيام "الإبراز" المحجوزة حاليًا (معلّقة أو معتمدة) خلال نافذة الأسبوع القادم
async function listFeaturedAvailability(){
  const { data, error } = await sb.from("featured_photo_availability").select("feature_date");
  if(error) throw error;
  return data.map(r => r.feature_date);
}

// كل الحجوزات (للإدارة فقط — RLS يسمح لها بكل الصفوف، ولباقي المستخدمين بصفوفهم هم بس)
async function listAllFeaturedBookings(){
  const { data, error } = await sb
    .from("featured_photo_bookings")
    .select("*, team:team_id(name)")
    .order("feature_date");
  if(error) throw error;
  return data;
}

// حجوزات فريقي أنا (كابتن) لمتابعة حالتها
async function listMyFeaturedBookings(){
  const { data, error } = await sb
    .from("featured_photo_bookings")
    .select("*")
    .order("feature_date");
  if(error) throw error;
  return data;
}

async function bookFeaturedPhoto(featureDate, imageUrl){
  const { data, error } = await sb.rpc("book_featured_photo", {
    p_feature_date: featureDate, p_image_url: imageUrl,
  });
  if(error) throw error;
  return data;
}

async function rejectFeaturedPhoto(bookingId){
  const { data, error } = await sb.rpc("reject_featured_photo", { p_booking_id: bookingId });
  if(error) throw error;
  return data;
}
