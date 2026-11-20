// Voice chat (included by steam.c, runs on the Steam thread): push-to-talk over the game's Steam
// sessions.
//   Capture: ISteamUser voice (Steam's own codec, its microphone settings) while the talk key is
//   held in the game's window.
//   Transport: ISteamNetworkingMessages channel 1 (the game's packets are channel 0), a star through
//   the host: a client sends to the host, the host plays it and sends it on to the other players.
//   Packet: 'V', codec ('S' Steam, 'P' 16-bit PCM at V_RATE: the test tone), the speaker's SteamID
//   (8 bytes; the host writes in who sent it, so nobody speaks for another), name length, name (the
//   in-game name, from Lua: coop_voice name; only shown), data.
//   Loop transport (steam_loop.txt, the harness): a second UDP socket on the loop port + 1000.
//   Playback: waveOut, a stream per speaker, V_RATE mono 16-bit; a new burst starts behind 60 ms of
//   silence, so late packets do not cut it.
//   Lua: CoopVoice_Talk(id, name, 1|0, avatar) when a speaker starts / stops (the "on" again every
//   V_SHOW ms while it talks: Lua drops a box nobody refreshed, so a lost "off" line does not leave
//   it up), CoopVoice_Me(name, 1|0, avatar) for our own key, CoopVoice_Avatar(id, avatar) once a
//   picture is there ("" id: ours). id: the speaker's SteamID in hex (the loop port in the loop).
//   The key works only in a running co-op game: we host one, or the host's packets came in the last
//   V_ALIVE ms (a client that left keeps g_host), and Lua did not hold it (coop_voice hold 1: the
//   chat line is open, so typing a K does not talk).
//   COOP/ClientStuff.lua draws them at the bottom right, as Source games do.
//   Avatar: the speaker's small Steam avatar (32x32 RGBA, ISteamFriends / ISteamUtils), written as
//   Mods/FarCryCoop/avatars/<SteamID hex>.dds for System:LoadImage; "" while there is none.
// Console: coop_voice [status] | on | off | key <k|mouse4|...|vk<VK number>> | volume <0-200>
//   | avatar <SteamID, decimal> (write that player's avatar, as for a speaker)
//   | name <name> | hold 1|0 | echo (hear yourself: the microphone check) | test [ms] (a tone instead
//   of the voice)

#define V_RATE 24000
#define V_BUFS 24             // wave headers per speaker
#define V_BUFSZ 9600          // bytes per header: 200 ms
#define V_LEAD 1440           // samples of silence ahead of a burst: 60 ms
#define V_MAXQ 12             // headers queued: more is too late, drop
#define V_QUIET 400           // ms without packets: the speaker is done
#define V_IDLE 30000          // ms without packets: close the speaker's stream
#define V_PORT_OFS 1000       // loop: the voice socket is the loop port + this
#define V_SPK (MAX_PEERS + 1) // remote speakers, and ourselves (echo)
#define V_SHOW 500            // ms: "talks" again for Lua while a speaker talks
#define V_ALIVE 3000          // ms: a client is in a game while the host's packets come
#define V_MAXPKT 4096         // bytes: a bigger packet is not voice (Steam's frames are small)

typedef struct { char *data; DWORD len, rec, user, flags, loops; void *next, *res; } WaveHdr;
typedef struct { WORD tag, ch; DWORD rate, bps; WORD align, bits, size; } WaveFmt;

static int(__stdcall *pWaveOpen)(HANDLE *, DWORD, const WaveFmt *, DWORD, DWORD, DWORD);
static int(__stdcall *pWavePrep)(HANDLE, WaveHdr *, DWORD);
static int(__stdcall *pWaveUnprep)(HANDLE, WaveHdr *, DWORD);
static int(__stdcall *pWaveWrite)(HANDLE, WaveHdr *, DWORD);
static int(__stdcall *pWaveReset)(HANDLE);
static int(__stdcall *pWaveClose)(HANDLE);
static short(__stdcall *pKeyState)(int);
static HANDLE(__stdcall *pForeground)(void);
static DWORD(__stdcall *pWindowPid)(HANDLE, DWORD *);
F(void, StartVoice, (void *));
F(void, StopVoice, (void *));
F(int, AvailVoice, (void *, DWORD *, DWORD *, DWORD));
F(int, GetVoice, (void *, int, void *, DWORD, DWORD *, int, void *, DWORD, DWORD *, DWORD));
F(int, Decompress, (void *, const void *, DWORD, void *, DWORD, DWORD *, DWORD));
F(int, SmallAvatar, (void *, U64));
F(BYTE, UserInfo, (void *, U64, int));
F(BYTE, ImageSize, (void *, int, DWORD *, DWORD *));
F(BYTE, ImageRGBA, (void *, int, BYTE *, int));
static void *g_sutils; // ISteamUtils (g_utils is ISteamNetworkingUtils)
static int(__stdcall *pMkDir)(const char *, void *);

static int g_vInit, g_vOn = 1, g_vKey = 'K', g_vVol = 100, g_vEcho;
static int g_vRec, g_vTalk, g_vSays = -1, g_vHold;
static DWORD g_vMeShown;
static DWORD g_vDrain, g_vTestUntil, g_vTestNext, g_vTestPhase, g_vSent, g_vGot;
static char g_vName[24] = "Player";
static SOCKET g_vSock = (SOCKET)-1;
static BYTE g_vPkt[32768 + 40];
static short g_vPcm[32768];
static struct {
	U64 id;
	HANDLE wo;
	WaveHdr h[V_BUFS];
	char *mem;
	DWORD last, since, shown;
	int talking, packets;
	char hex[20];
	char name[24];
} g_spk[V_SPK];

static void voiceInit(void)
{
	HANDLE w = LoadLibraryA("winmm.dll"), u = LoadLibraryA("user32.dll");
	g_vInit = 1;
	pWaveOpen = (int(__stdcall *)(HANDLE *, DWORD, const WaveFmt *, DWORD, DWORD, DWORD))GetProcAddress(w, "waveOutOpen");
	pWavePrep = (int(__stdcall *)(HANDLE, WaveHdr *, DWORD))GetProcAddress(w, "waveOutPrepareHeader");
	pWaveUnprep = (int(__stdcall *)(HANDLE, WaveHdr *, DWORD))GetProcAddress(w, "waveOutUnprepareHeader");
	pWaveWrite = (int(__stdcall *)(HANDLE, WaveHdr *, DWORD))GetProcAddress(w, "waveOutWrite");
	pWaveReset = (int(__stdcall *)(HANDLE))GetProcAddress(w, "waveOutReset");
	pWaveClose = (int(__stdcall *)(HANDLE))GetProcAddress(w, "waveOutClose");
	pKeyState = (short(__stdcall *)(int))GetProcAddress(u, "GetAsyncKeyState");
	pForeground = (HANDLE(__stdcall *)(void))GetProcAddress(u, "GetForegroundWindow");
	pWindowPid = (DWORD(__stdcall *)(HANDLE, DWORD *))GetProcAddress(u, "GetWindowThreadProcessId");
	if (!g_sLoop) { // optional: an old steam_api.dll without voice only loses the microphone
		StartVoice = (void(__cdecl *)(void *))GetProcAddress(g_api, "SteamAPI_ISteamUser_StartVoiceRecording");
		StopVoice = (void(__cdecl *)(void *))GetProcAddress(g_api, "SteamAPI_ISteamUser_StopVoiceRecording");
		AvailVoice = (int(__cdecl *)(void *, DWORD *, DWORD *, DWORD))GetProcAddress(g_api, "SteamAPI_ISteamUser_GetAvailableVoice");
		GetVoice = (int(__cdecl *)(void *, int, void *, DWORD, DWORD *, int, void *, DWORD, DWORD *, DWORD))GetProcAddress(g_api, "SteamAPI_ISteamUser_GetVoice");
		Decompress = (int(__cdecl *)(void *, const void *, DWORD, void *, DWORD, DWORD *, DWORD))GetProcAddress(g_api, "SteamAPI_ISteamUser_DecompressVoice");
		SmallAvatar = (int(__cdecl *)(void *, U64))GetProcAddress(g_api, "SteamAPI_ISteamFriends_GetSmallFriendAvatar");
		UserInfo = (BYTE(__cdecl *)(void *, U64, int))GetProcAddress(g_api, "SteamAPI_ISteamFriends_RequestUserInformation");
		ImageSize = (BYTE(__cdecl *)(void *, int, DWORD *, DWORD *))GetProcAddress(g_api, "SteamAPI_ISteamUtils_GetImageSize");
		ImageRGBA = (BYTE(__cdecl *)(void *, int, BYTE *, int))GetProcAddress(g_api, "SteamAPI_ISteamUtils_GetImageRGBA");
		{
			void *(__cdecl * su)(void) = (void *(__cdecl *)(void))GetProcAddress(g_api, "SteamAPI_SteamUtils_v011");
			g_sutils = su ? su() : 0;
		}
		pMkDir = (int(__stdcall *)(const char *, void *))GetProcAddress(LoadLibraryA("kernel32.dll"), "CreateDirectoryA");
	}
	if (!pWaveOpen || !pWavePrep || !pWaveWrite)
		logf("voice: no waveOut, nothing is played");
	if (!g_sLoop && (!StartVoice || !StopVoice || !AvailVoice || !GetVoice || !Decompress))
		logf("voice: steam_api.dll has no voice functions, no microphone");
}

// ---- avatars ----
#define V_AV 32
static struct { U64 id; int state, tries; DWORD next; char hex[20], name[24]; } g_av[V_AV]; // state: 1 asked, 2 written, 3 none
static void avHex(U64 id, char *out)
{
	DWORD a[2];
	a[0] = HI(id);
	a[1] = LO(id);
	wvsprintfA(out, "%x%08x", (va_list)a);
}
static int avWrite(int img, const char *hex) // the Steam image as an uncompressed 32-bit DDS
{
	static BYTE file[128 + 64 * 64 * 4];
	static char path[700];
	DWORD w = 0, h = 0, *hd = (DWORD *)file, done;
	int n = 0, i;
	HANDLE f;
	if (!ImageSize(g_sutils, img, &w, &h) || !w || w > 64 || h != w)
		return 0;
	memset(file, 0, 128);
	if (!ImageRGBA(g_sutils, img, file + 128, (int)(w * h * 4)))
		return 0;
	for (i = 128; i < 128 + (int)(w * h * 4); i += 4) { // RGBA -> BGRA
		BYTE t = file[i];
		file[i] = file[i + 2];
		file[i + 2] = t;
	}
	hd[0] = 0x20534444; // "DDS "
	hd[1] = 124;
	hd[2] = 0x1 | 0x2 | 0x4 | 0x1000 | 0x8;
	hd[3] = h;
	hd[4] = w;
	hd[5] = w * 4;
	hd[7] = 1;
	hd[19] = 32;
	hd[20] = 0x1 | 0x40; // ALPHAPIXELS | RGB
	hd[22] = 32;
	hd[23] = 0x00ff0000;
	hd[24] = 0x0000ff00;
	hd[25] = 0x000000ff;
	hd[26] = 0xff000000;
	hd[27] = 0x1000;
	while (g_join[n]) // the mod folder: g_join is <game>/Mods/FarCryCoop/join.txt
		n++;
	while (n > 0 && g_join[n - 1] != '\\')
		n--;
	for (i = 0; i < n; i++)
		path[i] = g_join[i];
	wvsprintfA(path + n, "avatars", 0);
	if (pMkDir)
		pMkDir(path, 0);
	{
		void *a[1];
		a[0] = (void *)hex;
		wvsprintfA(path + n + 7, "\\%s.dds", (va_list)a);
	}
	f = CreateFileA(path, 0x40000000, 0, 0, 2, 0x80, 0); // GENERIC_WRITE, CREATE_ALWAYS
	if (f == (HANDLE)-1)
		return 0;
	WriteFile(f, file, 128 + w * h * 4, &done, 0);
	CloseHandle(f);
	return 1;
}
static const char *avatar(U64 id, const char *name) // the avatar's name for Lua if written, else ""; asks for it
{
	int i, free = -1;
	if (g_sLoop || !SmallAvatar || !g_sutils || !ImageSize || !ImageRGBA)
		return "";
	for (i = 0; i < V_AV; i++) {
		if (g_av[i].state && g_av[i].id == id) {
			safeText(g_av[i].name, name, 20);
			return g_av[i].state == 2 ? g_av[i].hex : "";
		}
		if (free < 0 && !g_av[i].state)
			free = i;
	}
	if (free < 0)
		return "";
	g_av[free].id = id;
	g_av[free].state = 1;
	g_av[free].tries = 0;
	g_av[free].next = GetTickCount();
	avHex(id, g_av[free].hex);
	safeText(g_av[free].name, name, 20);
	if (UserInfo)
		UserInfo(g_friends, id, 0); // not a friend: Steam fetches the avatar too
	return "";
}
static void talkLine(const char *fn, const char *name, int on, const char *av);
static void avatarTick(void)
{
	int i, img;
	DWORD now = GetTickCount();
	for (i = 0; i < V_AV; i++) {
		if (g_av[i].state != 1 || (int)(now - g_av[i].next) < 0)
			continue;
		img = SmallAvatar(g_friends, g_av[i].id); // 0: none (yet), -1: loading
		if (img > 0 && avWrite(img, g_av[i].hex)) {
			g_av[i].state = 2;
			logf("voice: avatar of %s", g_av[i].id == g_me ? "ours" : g_av[i].name);
			talkLine("CoopVoice_Avatar", g_av[i].id == g_me ? "" : g_av[i].hex, -1, g_av[i].hex);
		} else if (++g_av[i].tries > 20)
			g_av[i].state = 3;
		else
			g_av[i].next = now + 1000;
	}
}

// ---- playback ----
static void spkClose(int i)
{
	int k;
	if (g_spk[i].wo) {
		pWaveReset(g_spk[i].wo);
		for (k = 0; k < V_BUFS; k++)
			pWaveUnprep(g_spk[i].wo, &g_spk[i].h[k], sizeof(WaveHdr));
		pWaveClose(g_spk[i].wo);
		g_spk[i].wo = 0;
	}
	g_spk[i].id = 0;
}
static int spkFind(U64 id, const char *name) // the speaker's slot, opened on its first packet; -1 if none
{
	int i, k, free = -1;
	WaveFmt f;
	for (i = 0; i < V_SPK; i++) {
		if (g_spk[i].wo && g_spk[i].id == id)
			return i;
		if (free < 0 && !g_spk[i].wo)
			free = i;
	}
	if (free < 0 || !pWaveOpen)
		return -1;
	i = free;
	if (!g_spk[i].mem && !(g_spk[i].mem = (char *)VirtualAlloc(0, V_BUFS * V_BUFSZ, 0x3000, 0x04)))
		return -1;
	f.tag = 1; // PCM
	f.ch = 1;
	f.rate = V_RATE;
	f.bps = V_RATE * 2;
	f.align = 2;
	f.bits = 16;
	f.size = 0;
	if (pWaveOpen(&g_spk[i].wo, 0xffffffff, &f, 0, 0, 0)) { // WAVE_MAPPER, no callback
		g_spk[i].wo = 0;
		logf("voice: waveOutOpen failed");
		return -1;
	}
	for (k = 0; k < V_BUFS; k++) {
		memset(&g_spk[i].h[k], 0, sizeof(WaveHdr));
		g_spk[i].h[k].data = g_spk[i].mem + k * V_BUFSZ;
		g_spk[i].h[k].len = V_BUFSZ;
		pWavePrep(g_spk[i].wo, &g_spk[i].h[k], sizeof(WaveHdr));
	}
	g_spk[i].id = id;
	g_spk[i].talking = 0;
	g_spk[i].last = GetTickCount();
	avHex(id, g_spk[i].hex);
	safeText(g_spk[i].name, name, 20);
	if (!g_spk[i].name[0])
		safeText(g_spk[i].name, "Player", 20);
	return i;
}
static void spkWrite(int i, const short *pcm, int n, int scale) // n samples; scale: volume in %
{
	int k, j, queued = 0, at = -1;
	short *d;
	for (k = 0; k < V_BUFS; k++)
		if (g_spk[i].h[k].flags & 0x10) // WHDR_INQUEUE
			queued++;
		else if (at < 0)
			at = k;
	if (at < 0 || queued >= V_MAXQ)
		return; // too far behind: drop
	if (!queued) { // a new burst (or the queue ran dry): some silence first
		memset(g_spk[i].h[at].data, 0, V_LEAD * 2);
		g_spk[i].h[at].len = V_LEAD * 2;
		pWaveWrite(g_spk[i].wo, &g_spk[i].h[at], sizeof(WaveHdr));
		for (at = -1, k = 0; k < V_BUFS && at < 0; k++)
			if (!(g_spk[i].h[k].flags & 0x10))
				at = k;
		if (at < 0)
			return;
	}
	while (n > 0) { // a header holds 200 ms: a longer chunk takes several
		int m = n > V_BUFSZ / 2 ? V_BUFSZ / 2 : n;
		d = (short *)g_spk[i].h[at].data;
		for (j = 0; j < m; j++) {
			int s = pcm[j] * scale / 100;
			d[j] = (short)(s > 32767 ? 32767 : s < -32768 ? -32768 : s);
		}
		g_spk[i].h[at].len = m * 2;
		pWaveWrite(g_spk[i].wo, &g_spk[i].h[at], sizeof(WaveHdr));
		pcm += m;
		n -= m;
		for (at = -1, k = 0; n > 0 && k < V_BUFS && at < 0; k++)
			if (!(g_spk[i].h[k].flags & 0x10))
				at = k;
		if (n > 0 && at < 0)
			return;
	}
}
// name, and id when given: the Lua line fn("id","name",on,"av"); on -1: fn("name","av")
static void talkLine(const char *fn, const char *name, int on, const char *av)
{
	static char line[200];
	void *a[5]; // fn twice: wvsprintf has no positional arguments
	a[0] = (void *)fn;
	a[1] = (void *)fn;
	a[2] = (void *)name;
	if (on < 0) {
		a[3] = (void *)av;
		wvsprintfA(line, "#if %s then %s(\"%s\",\"%s\") end", (va_list)a);
	} else {
		a[3] = (void *)on;
		a[4] = (void *)av;
		wvsprintfA(line, "#if %s then %s(\"%s\",%d,\"%s\") end", (va_list)a);
	}
	runOnMain(line);
}
static void spkLine(int i, int on, const char *av) // CoopVoice_Talk("id","name",on,"av")
{
	static char line[200];
	void *a[4];
	a[0] = (void *)g_spk[i].hex;
	a[1] = (void *)g_spk[i].name;
	a[2] = (void *)on;
	a[3] = (void *)av;
	wvsprintfA(line, "#if CoopVoice_Talk then CoopVoice_Talk(\"%s\",\"%s\",%d,\"%s\") end", (va_list)a);
	runOnMain(line);
}
#define V_HDR 11 // 'V', codec, SteamID, name length
static void voicePlay(U64 id, const BYTE *p, int n) // a checked packet of the speaker id
{
	int i, nl = p[10], samples = 0;
	char name[24];
	const BYTE *data = p + V_HDR + nl;
	int len = n - V_HDR - nl;
	for (i = 0; i < nl && i < 23; i++)
		name[i] = (char)p[V_HDR + i];
	name[i] = 0;
	if (p[1] == 'P') {
		samples = len / 2;
		if (samples > (int)(sizeof g_vPcm / 2))
			samples = sizeof g_vPcm / 2;
		memcpy(g_vPcm, data, samples * 2);
	} else if (p[1] == 'S' && Decompress) {
		DWORD got = 0;
		if (Decompress(g_user, data, (DWORD)len, g_vPcm, sizeof g_vPcm, &got, V_RATE) == 0)
			samples = (int)(got / 2);
	}
	if (samples <= 0 || (i = spkFind(id, name)) < 0) // decoded first: nothing to play opens no device
		return;
	spkWrite(i, g_vPcm, samples, g_vVol);
	g_spk[i].last = GetTickCount();
	g_spk[i].packets++;
	g_vGot++;
	if (!g_spk[i].talking) {
		g_spk[i].talking = 1;
		g_spk[i].packets = 1;
		g_spk[i].since = g_spk[i].shown = g_spk[i].last;
		logf("voice: %s talks", g_spk[i].name);
		spkLine(i, 1, avatar(id, g_spk[i].name));
	} else if ((int)(g_spk[i].last - g_spk[i].shown) >= V_SHOW) {
		g_spk[i].shown = g_spk[i].last;
		spkLine(i, 1, avatar(id, g_spk[i].name));
	}
}

// ---- transport ----
static void voiceSendTo(U64 to, const BYTE *p, int n)
{
	if (g_sLoop) {
		Addr a;
		if (g_vSock == (SOCKET)-1)
			return;
		a = addr(LOCALHOST, (int)LO(to) + V_PORT_OFS);
		pSendTo(g_vSock, (const char *)p, n, 0, &a, sizeof a);
	} else {
		Identity id;
		memset(&id, 0, sizeof id);
		id.type = 16;
		id.size = 8;
		id.u.steamID = to;
		SendToUser(g_msgs, &id, p, (DWORD)n, SEND_FLAGS, 1);
	}
}
static int voiceSend(const BYTE *p, int n, U64 except) // to everybody in the game but except; how many
{
	int i, sent = 0;
	if (g_up) {
		for (i = 0; i < MAX_PEERS; i++)
			if (g_peers[i].s != (SOCKET)-1 && g_peers[i].id != except) {
				voiceSendTo(g_peers[i].id, p, n);
				sent++;
			}
	} else if (g_host && g_host != except) {
		voiceSendTo(g_host, p, n);
		sent = 1;
	}
	return sent;
}
static int isPeer(U64 id)
{
	int i;
	for (i = 0; i < MAX_PEERS; i++)
		if (g_peers[i].s != (SOCKET)-1 && g_peers[i].id == id)
			return 1;
	return 0;
}
static U64 myId(void) // as the host knows us: the SteamID, the loop port in the loop
{
	return g_sLoop ? (U64)g_loopPort : g_me;
}
static void voiceReceived(U64 from, BYTE *p, int n)
{
	U64 id, me = myId();
	if (n < V_HDR + 1 || n > V_MAXPKT || p[0] != 'V' || (p[1] != 'S' && p[1] != 'P') || p[10] > 20 || n < V_HDR + p[10] + 1)
		return;
	if (g_up) { // host: from one of our players only, as itself; send it on to the others
		if (!isPeer(from))
			return;
		memcpy(p + 2, &from, 8);
		voiceSend(p, n, from);
		id = from;
	} else if (from == g_host) {
		memcpy(&id, p + 2, 8);
		if (id == me)
			return;
	} else
		return;
	if (g_vOn)
		voicePlay(id, p, n);
}
static void voicePack(BYTE codec, const BYTE *data, int len, int *n)
{
	int nl = 0;
	while (g_vName[nl])
		nl++;
	g_vPkt[0] = 'V';
	U64 me = myId();
	g_vPkt[1] = codec;
	memcpy(g_vPkt + 2, &me, 8);
	g_vPkt[10] = (BYTE)nl;
	memcpy(g_vPkt + V_HDR, g_vName, nl);
	memcpy(g_vPkt + V_HDR + nl, data, len);
	*n = V_HDR + nl + len;
}

// ---- the Steam thread's tick ----
static int keyDown(void) // the talk key, while the game's window is in front
{
	DWORD pid = 0;
	HANDLE w;
	if (!pKeyState || !pForeground || !pWindowPid || !(pKeyState(g_vKey) & 0x8000))
		return 0;
	w = pForeground();
	if (!w)
		return 0;
	pWindowPid(w, &pid);
	return pid == GetCurrentProcessId();
}
static int inGame(DWORD now) // a running co-op game to talk to
{
	return g_up || (g_host && (int)(now - g_hostLast) < V_ALIVE);
}
static void voiceTick(void)
{
	static BYTE cap[V_MAXPKT - 40];
	DWORD now = GetTickCount();
	int i, n;
	if (!g_vInit)
		voiceInit();
	// microphone: the key held in a game (or echo on)
	if (!g_sLoop && StartVoice) {
		int talk = g_vOn && (g_vEcho || (!g_vHold && inGame(now) && keyDown()));
		if (talk != g_vTalk || (talk && !g_vEcho && (int)(now - g_vMeShown) >= V_SHOW)) {
			g_vTalk = talk;
			g_vMeShown = now;
			if (!g_vEcho)
				talkLine("CoopVoice_Me", g_vName, talk, avatar(g_me, ""));
		}
		if (talk && !g_vRec) {
			StartVoice(g_user);
			g_vRec = 1;
		} else if (!talk && g_vRec) {
			StopVoice(g_user); // Steam still hands out what it recorded: read it for a while
			g_vRec = 0;
			g_vDrain = now;
		}
		if (g_vRec || (int)(now - g_vDrain) < 500) {
			DWORD avail = 0, got = 0;
			int r = AvailVoice(g_user, &avail, 0, 0);
			if (r != g_vSays && g_vRec) { // EVoiceResult: 0 OK, 2 not recording, 3 no data, 6 restricted
				g_vSays = r;
				logf("voice: recording, Steam says %d", r);
			}
			if (r == 0 && avail > 0 &&
			    GetVoice(g_user, 1, cap, sizeof cap, &got, 0, 0, 0, 0, 0) == 0 && got > 0 && got <= sizeof cap) {
				voicePack('S', cap, (int)got, &n);
				if (g_vEcho)
					voicePlay(g_me, g_vPkt, n);
				else if (voiceSend(g_vPkt, n, 0))
					g_vSent++;
			}
		}
	}
	// the test tone: 20 ms packets of a 400 Hz triangle
	if (g_vTestUntil && (int)(now - g_vTestNext) >= 0) {
		static short tone[480];
		int s;
		if ((int)(now - g_vTestUntil) >= 0) {
			g_vTestUntil = 0;
			logf("voice: test done, %u packets sent", g_vSent);
			talkLine("CoopVoice_Me", g_vName, 0, "");
		} else {
			for (s = 0; s < 480; s++, g_vTestPhase = (g_vTestPhase + 1) % 60)
				tone[s] = (short)((g_vTestPhase < 30 ? (int)g_vTestPhase * 400 - 6000 : (60 - (int)g_vTestPhase) * 400 - 6000));
			voicePack('P', (const BYTE *)tone, sizeof tone, &n);
			if (voiceSend(g_vPkt, n, 0))
				g_vSent++;
			g_vTestNext += 20;
			if ((int)(now - g_vMeShown) >= V_SHOW) {
				g_vMeShown = now;
				talkLine("CoopVoice_Me", g_vName, 1, avatar(g_me, ""));
			}
		}
	}
	// incoming
	if (g_sLoop) {
		Addr from;
		int len;
		static int bound;
		if (g_vSock != (SOCKET)-1 && bound != g_loopPort) { // joined first, hosts now
			pClose(g_vSock);
			g_vSock = (SOCKET)-1;
		}
		if (g_vSock == (SOCKET)-1 && g_loopPort && (g_vSock = udp(g_loopPort + V_PORT_OFS)) != (SOCKET)-1)
			bound = g_loopPort;
		if (g_vSock != (SOCKET)-1) {
			len = sizeof from;
			while ((n = pRecvFrom(g_vSock, (char *)g_buf, sizeof g_buf, 0, &from, &len)) > 0) {
				int port = ((from.port & 0xff) << 8) | ((from.port >> 8) & 0xff);
				voiceReceived((U64)(port - V_PORT_OFS), g_buf, n);
				len = sizeof from;
			}
		}
	} else {
		void *msgs[32];
		while ((n = Receive(g_msgs, 1, msgs, 32)) > 0)
			for (i = 0; i < n; i++) {
				voiceReceived(MSG_FROM(msgs[i]), MSG_DATA(msgs[i]), MSG_SIZE(msgs[i]));
				Release(msgs[i]);
			}
	}
	if (!g_sLoop)
		avatarTick();
	// speakers that went quiet
	for (i = 0; i < V_SPK; i++) {
		if (!g_spk[i].wo)
			continue;
		if (g_spk[i].talking && (int)(now - g_spk[i].last) > V_QUIET) { // signed: last may be newer than now
			void *a[3];
			static char line[120];
			g_spk[i].talking = 0;
			a[0] = (void *)g_spk[i].name;
			a[1] = (void *)g_spk[i].packets;
			a[2] = (void *)(g_spk[i].last - g_spk[i].since);
			wvsprintfA(line, "voice: %s done, %d packets, %u ms", (va_list)a);
			logf("%s", line);
			spkLine(i, 0, "");
		}
		if ((int)(now - g_spk[i].last) > V_IDLE)
			spkClose(i);
	}
}

static int keyCode(const char *s) // a key name (as the game's binds call them) or a VK number
{
	int n = 0;
	if (starts(s, "vk")) { // a VK number (the controls menu sends these)
		for (s += 2; *s >= '0' && *s <= '9'; s++)
			n = n * 10 + *s - '0';
		return n > 0 && n < 256 ? n : 0;
	}
	if (starts(s, "mouse3"))
		return 0x04;
	if (starts(s, "mouse4"))
		return 0x05;
	if (starts(s, "mouse5"))
		return 0x06;
	if (starts(s, "capslock"))
		return 0x14;
	if (starts(s, "lalt"))
		return 0xa4;
	if (starts(s, "ralt"))
		return 0xa5;
	if (starts(s, "rctrl"))
		return 0xa3;
	if (starts(s, "rshift"))
		return 0xa1;
	if (s[0] == 'f' && s[1] >= '1' && s[1] <= '9') {
		n = s[1] - '0';
		if (s[2] >= '0' && s[2] <= '2')
			n = n * 10 + s[2] - '0';
		return n <= 12 ? 0x6f + n : 0;
	}
	if (s[0] >= 'a' && s[0] <= 'z' && (!s[1] || s[1] == ' '))
		return s[0] - 32;
	if (s[0] >= 'A' && s[0] <= 'Z' && (!s[1] || s[1] == ' '))
		return s[0];
	if (s[0] >= '0' && s[0] <= '9' && (!s[1] || s[1] == ' '))
		return s[0];
	return 0;
}
// a SteamID written in decimal (no CRT: no 64-bit multiply, so x10 on the two halves by hand)
static U64 decU64(const char *s)
{
	U64 r = 0;
	DWORD hi = 0, lo = 0, a, b;
	for (; *s >= '0' && *s <= '9'; s++) {
		a = (lo & 0xffff) * 10 + (DWORD)(*s - '0');
		b = (lo >> 16) * 10 + (a >> 16);
		lo = (a & 0xffff) | (b << 16);
		hi = hi * 10 + (b >> 16);
	}
	HI(r) = hi;
	((DWORD *)&r)[0] = lo;
	return r;
}
static void voiceCommand(char *c) // "coop_voice ..." without the "coop_voice"
{
	void *a[8];
	static char line[300];
	if (!g_vInit)
		voiceInit();
	while (*c == ' ')
		c++;
	if (starts(c, "on")) {
		g_vOn = 1;
		g_vEcho = 0;
	} else if (starts(c, "off")) {
		g_vOn = 0;
		g_vEcho = 0;
	} else if (starts(c, "key ")) {
		int k = keyCode(c + 4);
		if (k)
			g_vKey = k;
		else
			say("coop_voice key: a letter, a digit, f1-f12, mouse3-5, capslock, lalt, ralt, rctrl, rshift or vk<VK number>");
	} else if (starts(c, "volume ")) {
		int v = 0;
		for (c += 7; *c >= '0' && *c <= '9'; c++)
			v = v * 10 + *c - '0';
		g_vVol = v > 200 ? 200 : v;
	} else if (starts(c, "name ")) {
		safeText(g_vName, c + 5, 20);
		if (!g_vName[0])
			safeText(g_vName, "Player", 20);
		return; // quietly: the game sets it on every map
	} else if (starts(c, "hold ")) {
		g_vHold = c[5] == '1';
		return; // quietly: the chat line sets it
	} else if (starts(c, "avatar ")) {
		// the in-game menu's player list (MenuScreens/CoopInGame.lua) asks for a player's avatar:
		// CoopVoice_Avatar("<hex>", "<hex>") once it is written, at once if it already is
		U64 id = decU64(c + 7);
		const char *av;
		if (!id)
			return;
		if (!g_vInit)
			voiceInit();
		av = avatar(id, "");
		if (av[0])
			talkLine("CoopVoice_Avatar", id == g_me ? "" : av, -1, av);
		return; // quietly: the menu asks often
	} else if (starts(c, "echo")) {
		g_vEcho = !g_vEcho;
		if (g_sLoop || !StartVoice)
			say("voice: no microphone here (loop or no Steam voice)");
	} else if (starts(c, "test")) {
		int ms = 0;
		for (c += 4; *c == ' '; c++)
			;
		for (; *c >= '0' && *c <= '9'; c++)
			ms = ms * 10 + *c - '0';
		g_vTestNext = GetTickCount();
		g_vTestUntil = g_vTestNext + (ms > 0 && ms <= 10000 ? ms : 1000);
		g_vSent = 0;
		talkLine("CoopVoice_Me", g_vName, 1, avatar(g_me, ""));
	}
	a[0] = (void *)(g_vOn ? (g_vEcho ? "echo (you hear yourself)" : "on") : "off");
	a[1] = (void *)g_vKey;
	a[2] = (void *)g_vVol;
	a[3] = (void *)g_vName;
	a[4] = (void *)(g_sLoop ? "loop" : StartVoice ? "Steam" : "none");
	a[5] = (void *)g_vSent;
	a[6] = (void *)g_vGot;
	wvsprintfA(line, "voice %s, key VK %d, volume %d%%, name %s, microphone %s; sent %u, played %u", (va_list)a);
	say("%s", line);
}
