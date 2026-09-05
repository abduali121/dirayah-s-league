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
