// يبني بيانات جدول الترتيب: الرصيد الحالي، الفوز/الخسارة، والتغيّر عن آخر لقطة أسبوعية محفوظة
async function fetchStandings(){
  const { data: teams, error: teamsErr } = await sb
    .from("teams")
    .select("id, name, logo_url, primary_color, balance_daraya")
    .order("balance_daraya", { ascending: false });
  if(teamsErr) throw teamsErr;

  const { data: matches, error: matchesErr } = await sb
    .from("matches")
    .select("team_a_id, team_b_id, winner_team_id, status");
  if(matchesErr) throw matchesErr;

  const statsByTeam = {};
  teams.forEach(t => statsByTeam[t.id] = { wins: 0, losses: 0 });
  (matches || []).forEach(m => {
    if(m.status !== "completed" || !m.winner_team_id) return;
    const loserId = m.winner_team_id === m.team_a_id ? m.team_b_id : m.team_a_id;
    if(statsByTeam[m.winner_team_id]) statsByTeam[m.winner_team_id].wins++;
    if(statsByTeam[loserId]) statsByTeam[loserId].losses++;
  });

  // آخر لقطة أسبوعية متاحة لحساب اتجاه التغيّر (▲▼)
  const { data: snapshots } = await sb
    .from("standings_snapshots")
    .select("week_id, team_id, rank, created_at")
    .order("created_at", { ascending: false })
    .limit(60);

  let prevRankByTeam = {};
  if(snapshots && snapshots.length){
    const latestWeek = snapshots[0].week_id;
    const previousWeekRows = snapshots.filter(s => s.week_id !== latestWeek);
    if(previousWeekRows.length){
      const prevWeek = previousWeekRows[0].week_id;
      previousWeekRows.filter(s => s.week_id === prevWeek).forEach(s => prevRankByTeam[s.team_id] = s.rank);
    }
  }

  return teams.map((t, idx) => {
    const rank = idx + 1;
    const prevRank = prevRankByTeam[t.id];
    let trend = "same";
    if(prevRank !== undefined){
      if(prevRank > rank) trend = "up";
      else if(prevRank < rank) trend = "down";
    }
    return {
      ...t,
      rank,
      wins: statsByTeam[t.id].wins,
      losses: statsByTeam[t.id].losses,
      trend,
    };
  });
}
