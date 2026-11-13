// Steam inside the game (included by FarCryCoopNet.c; replaces the separate FarCryCoopSteam.exe).
// The game itself still only talks UDP on 127.0.0.1, as on a LAN; a thread of this process moves
// those packets over Steam (ISteamNetworkingMessages: NAT punch, else Valve relays).
//   Host: while this process holds UDP 49001 (a Far Cry server runs in it), rich presence
//   "connect" is set, so friends see Join. Every remote player gets a local UDP socket that
//   talks to the server on 127.0.0.1:49001.
//   Client: Join, an accepted invite, a lobby or "coop_steam join <SteamID>" give the host;
//   the tunnel listens on 127.0.0.1:49011 and the game connects there.
// Runs as Far Cry (AppID 13520: SteamAppId in the environment, as Steam sets it when it starts
// the game). Off unless Mods\FarCryCoop\Steam\steam_api.dll is there (SDK redistributable, x86).
// Mods\FarCryCoop\steam_loop.txt: no Steam, the "Steam" between two games on one PC is UDP on
// 127.0.0.1 (host 49021, clients 49022+; an id is that port): the harness test of the tunnel.
// Console (typed, or System:ExecuteCommand from Lua; caught in IConsole::ExecuteString):
//   coop_steam status | join <hex SteamID>|loop | host <max>|key=value|... | find | joinlobby <n>
//   coop_steam leave | invite
// All Steam calls run on the Steam thread; console lines go back to the main thread (hGameUpdate).

typedef unsigned __int64 U64;
typedef unsigned int SOCKET;
#define HI(u64) (((DWORD *)&(u64))[1]) // no CRT: a 64-bit shift by a variable would call __aullshr
#define LO(u64) ((DWORD)(u64))

#define SV_PORT 49001     // Far Cry sv_port default
#define CL_PORT 49011     // the client's game connects here
#define LOOP_HOST 49021   // -loop: the host's fake SteamID (its loop port)
#define MAX_PEERS 16
#define PEER_IDLE 60000   // ms without packets: drop a remote player's local socket
#define NET_KEY "1"       // lobby data fc1coop: lobbies of other mod builds are not listed
#define MAX_ROWS 32

static int g_sOn, g_sOff, g_sLoop; // Steam module on; failed to start; loop transport instead of Steam
static DWORD g_sCs[6];      // CRITICAL_SECTION: the queues below
static char g_inQ[8][300];  // console -> Steam thread
static int g_inHead, g_inTail;
static char g_outQ[32][300]; // Steam thread -> main thread: lines to print (dropped when full)
static int g_outHead, g_outTail;
static char g_exQ[8][300];   // Steam thread -> main thread: lines to run (own queue: prints never push them out)
static int g_exHead, g_exTail;

static void qPut(char (*q)[300], int size, int *head, int tail, char kind, const char *s)
{
	int i, next;
	EnterCriticalSection(g_sCs);
	next = (*head + 1) % size;
	if (next != tail) {
		char *d = q[*head];
		i = 0;
		if (kind)
			d[i++] = kind;
		for (; i < 299 && *s; s++)
			d[i++] = *s;
		d[i] = 0;
		*head = next;
	}
	LeaveCriticalSection(g_sCs);
}
static int qGet(char (*q)[300], int size, int head, int *tail, char *out)
{
	int got = 0, i;
	EnterCriticalSection(g_sCs);
	if (*tail != head) {
		for (i = 0; i < 299 && q[*tail][i]; i++)
			out[i] = q[*tail][i];
		out[i] = 0;
		*tail = (*tail + 1) % size;
		got = 1;
	}
	LeaveCriticalSection(g_sCs);
	return got;
}

static int starts(const char *s, const char *t) // s begins with t (letters in any case)
{
	for (; *t; s++, t++)
		if ((*s >= 'A' && *s <= 'Z' ? *s + 32 : *s) != *t)
			return 0;
	return 1;
}

static void say(const char *fmt, ...) // log and the game console
{
	char buf[1024 + 2];
	va_list va;
	va_start(va, fmt);
	wvsprintfA(buf, fmt, va);
	va_end(va);
	logf("steam: %s", buf);
	qPut(g_outQ, 32, &g_outHead, g_outTail, 0, buf);
}
static void runOnMain(const char *line)
{
	qPut(g_exQ, 8, &g_exHead, g_exTail, 0, line);
}
static void conPrint(void *con, const char *s) // IConsole::PrintLine
{
	((void(__fastcall *)(void *, void *, const char *))VFN(con, 0x64))(con, 0, s);
}

// ---- console hook (main thread) ----
static void(__fastcall *oExec)(void *, void *, const char *, int, int);
static void __fastcall hExec(void *con, void *edx, const char *cmd, int slash, int dev)
{
	const char *c = cmd;
	if (c) {
		while (*c == ' ' || *c == '\\' || *c == '/')
			c++;
		if (starts(c, "coop_steam") && (!c[10] || c[10] == ' ')) {
			for (c += 10; *c == ' '; c++)
				;
			if (g_sOff) { // the Steam thread gave up: nobody reads the queue
				conPrint(con, "coop_steam: Steam is off (see the netlog)");
				oExec(con, edx, "#if CoopSteam_OnLobby then CoopSteam_OnLobby(0) end", 0, 1);
			} else
				qPut(g_inQ, 8, &g_inHead, g_inTail, 0, c);
			return;
		}
	}
	oExec(con, edx, cmd, slash, dev);
}
static void steamFrame(void) // from hGameUpdate: console lines of the Steam thread
{
	static char line[300];
	void *sys, *con;
	if (!g_sOn)
		return;
	sys = getISystem();
	con = sys ? ((void *(__fastcall *)(void *, void *))VFN(sys, 0x60))(sys, 0) : 0;
	if (!con)
		return;
	while (qGet(g_outQ, 32, g_outHead, &g_outTail, line))
		conPrint(con, line);
	while (qGet(g_exQ, 8, g_exHead, &g_exTail, line)) {
		if (hasText(line, "Game:Connect("))
			g_coop = 1;
		logf("steam: run %s", line);
		oExec(con, 0, line, 0, 1);
	}
}

// ---- run-time imports (ws2_32, iphlpapi, steam_api) ----
typedef struct { short family; WORD port; DWORD ip; BYTE zero[8]; } Addr; // sockaddr_in
static int(__stdcall *pWSAStartup)(WORD, void *);
static SOCKET(__stdcall *pSocket)(int, int, int);
static int(__stdcall *pBind)(SOCKET, const void *, int);
static int(__stdcall *pClose)(SOCKET);
static int(__stdcall *pIoctl)(SOCKET, long, DWORD *);
static int(__stdcall *pRecvFrom)(SOCKET, char *, int, int, void *, int *);
static int(__stdcall *pSendTo)(SOCKET, const char *, int, int, const void *, int);
static DWORD(__stdcall *pUdpTable)(void *, DWORD *, BOOL, DWORD, int, DWORD);

typedef struct { int type; int size; union { U64 steamID; BYTE raw[128]; } u; } Identity; // SteamNetworkingIdentity, pack 1
typedef struct { int user; int id; BYTE *param; int size; } CallbackMsg;                  // CallbackMsg_t
#define MSG_DATA(m) (*(BYTE **)(m))              // SteamNetworkingMessage_t::m_pData
#define MSG_SIZE(m) (*(int *)((BYTE *)(m) + 4))  // m_cbSize
#define MSG_FROM(m) (*(U64 *)((BYTE *)(m) + 20)) // m_identityPeer (at 12) .m_steamID64 (at +8)
// callbacks (Windows packs them at 8)
#define CB_CALL_DONE 703        // SteamAPICallCompleted_t { U64 call; int id; uint cb; }
#define CB_SESSION_REQUEST 1251 // SteamNetworkingMessagesSessionRequest_t { Identity remote; }
#define CB_JOIN_REQUESTED 337   // GameRichPresenceJoinRequested_t { U64 friend; char connect[256]; }
#define CB_LOBBY_JOIN_REQ 333   // GameLobbyJoinRequested_t { U64 lobby; U64 friend; }
#define CB_LOBBY_ENTER 504      // LobbyEnter_t { U64 lobby; uint perms; bool locked; uint response; } (1 = success)
#define CB_LOBBY_CREATED 513    // LobbyCreated_t { int result; U64 lobby; } (result 1 = OK)
#define CB_LOBBY_LIST 510       // LobbyMatchList_t { uint count; }
#define SEND_FLAGS (0 | 1 | 32) // Unreliable | NoNagle | AutoRestartBrokenSession

static HANDLE g_api;
static int g_symMissing;
static void *sym(const char *name)
{
	void *f = GetProcAddress(g_api, name);
	if (!f && !g_symMissing++)
		logf("steam: steam_api.dll has no %s: wrong version, Steam off", name);
	return f;
}
#define F(ret, name, args) static ret(__cdecl *name) args
F(int, InitFlat, (char *));
F(void, DispatchInit, (void));
F(int, GetPipe, (void));
F(void, RunFrame, (int));
F(BYTE, NextCallback, (int, CallbackMsg *));
F(void, FreeCallback, (int));
F(BYTE, CallResult, (int, U64, void *, int, int, BYTE *));
F(U64, GetSteamID, (void *));
F(const char *, PersonaName, (void *));
F(BYTE, SetRichPresence, (void *, const char *, const char *));
F(void, ClearRichPresence, (void *));
F(BYTE, HasFriend, (void *, U64, int));
F(void, InviteDialog, (void *, U64));
F(int, SendToUser, (void *, const Identity *, const void *, DWORD, int, int));
F(int, Receive, (void *, int, void **, int));
F(BYTE, AcceptSession, (void *, const Identity *));
F(void, InitRelay, (void *));
F(int, RelayStatus, (void *, void *));
F(void, Release, (void *));
F(U64, CreateLobby, (void *, int, int));
F(BYTE, SetLobbyData, (void *, U64, const char *, const char *));
F(const char *, GetLobbyData, (void *, U64, const char *));
F(void, StrFilter, (void *, const char *, const char *, int));
F(void, DistFilter, (void *, int));
F(U64, RequestList, (void *));
F(U64, LobbyByIndex, (void *, int));
F(U64, LobbyOwner, (void *, U64));
F(int, LobbyMembers, (void *, U64));
F(U64, LobbyMember, (void *, U64, int));
F(int, LobbyLimit, (void *, U64));
F(U64, JoinLobby, (void *, U64));
F(void, LeaveLobby, (void *, U64));
static void *g_user, *g_friends, *g_msgs, *g_utils, *g_mm;
static int g_pipe;

static int steamInit(const char *dll)
{
	static char err[1024];
	if (!(g_api = LoadLibraryA(dll))) {
		logf("steam: no %s, Steam off", dll);
		return 0;
	}
	InitFlat = (int(__cdecl *)(char *))sym("SteamAPI_InitFlat");
	DispatchInit = (void(__cdecl *)(void))sym("SteamAPI_ManualDispatch_Init");
	GetPipe = (int(__cdecl *)(void))sym("SteamAPI_GetHSteamPipe");
	RunFrame = (void(__cdecl *)(int))sym("SteamAPI_ManualDispatch_RunFrame");
	NextCallback = (BYTE(__cdecl *)(int, CallbackMsg *))sym("SteamAPI_ManualDispatch_GetNextCallback");
	FreeCallback = (void(__cdecl *)(int))sym("SteamAPI_ManualDispatch_FreeLastCallback");
	CallResult = (BYTE(__cdecl *)(int, U64, void *, int, int, BYTE *))sym("SteamAPI_ManualDispatch_GetAPICallResult");
	GetSteamID = (U64(__cdecl *)(void *))sym("SteamAPI_ISteamUser_GetSteamID");
	PersonaName = (const char *(__cdecl *)(void *))sym("SteamAPI_ISteamFriends_GetPersonaName");
	SetRichPresence = (BYTE(__cdecl *)(void *, const char *, const char *))sym("SteamAPI_ISteamFriends_SetRichPresence");
	ClearRichPresence = (void(__cdecl *)(void *))sym("SteamAPI_ISteamFriends_ClearRichPresence");
	HasFriend = (BYTE(__cdecl *)(void *, U64, int))sym("SteamAPI_ISteamFriends_HasFriend");
	InviteDialog = (void(__cdecl *)(void *, U64))sym("SteamAPI_ISteamFriends_ActivateGameOverlayInviteDialog");
	SendToUser = (int(__cdecl *)(void *, const Identity *, const void *, DWORD, int, int))sym("SteamAPI_ISteamNetworkingMessages_SendMessageToUser");
	Receive = (int(__cdecl *)(void *, int, void **, int))sym("SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel");
	AcceptSession = (BYTE(__cdecl *)(void *, const Identity *))sym("SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser");
	InitRelay = (void(__cdecl *)(void *))sym("SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess");
	RelayStatus = (int(__cdecl *)(void *, void *))sym("SteamAPI_ISteamNetworkingUtils_GetRelayNetworkStatus");
	Release = (void(__cdecl *)(void *))sym("SteamAPI_SteamNetworkingMessage_t_Release");
	CreateLobby = (U64(__cdecl *)(void *, int, int))sym("SteamAPI_ISteamMatchmaking_CreateLobby");
	SetLobbyData = (BYTE(__cdecl *)(void *, U64, const char *, const char *))sym("SteamAPI_ISteamMatchmaking_SetLobbyData");
	GetLobbyData = (const char *(__cdecl *)(void *, U64, const char *))sym("SteamAPI_ISteamMatchmaking_GetLobbyData");
	StrFilter = (void(__cdecl *)(void *, const char *, const char *, int))sym("SteamAPI_ISteamMatchmaking_AddRequestLobbyListStringFilter");
	DistFilter = (void(__cdecl *)(void *, int))sym("SteamAPI_ISteamMatchmaking_AddRequestLobbyListDistanceFilter");
	RequestList = (U64(__cdecl *)(void *))sym("SteamAPI_ISteamMatchmaking_RequestLobbyList");
	LobbyByIndex = (U64(__cdecl *)(void *, int))sym("SteamAPI_ISteamMatchmaking_GetLobbyByIndex");
	LobbyOwner = (U64(__cdecl *)(void *, U64))sym("SteamAPI_ISteamMatchmaking_GetLobbyOwner");
	LobbyMembers = (int(__cdecl *)(void *, U64))sym("SteamAPI_ISteamMatchmaking_GetNumLobbyMembers");
	LobbyMember = (U64(__cdecl *)(void *, U64, int))sym("SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex");
	LobbyLimit = (int(__cdecl *)(void *, U64))sym("SteamAPI_ISteamMatchmaking_GetLobbyMemberLimit");
	JoinLobby = (U64(__cdecl *)(void *, U64))sym("SteamAPI_ISteamMatchmaking_JoinLobby");
	LeaveLobby = (void(__cdecl *)(void *, U64))sym("SteamAPI_ISteamMatchmaking_LeaveLobby");
	{
		void *(__cdecl * u)(void) = (void *(__cdecl *)(void))sym("SteamAPI_SteamUser_v023");
		void *(__cdecl * f)(void) = (void *(__cdecl *)(void))sym("SteamAPI_SteamFriends_v018");
		void *(__cdecl * m)(void) = (void *(__cdecl *)(void))sym("SteamAPI_SteamNetworkingMessages_SteamAPI_v002");
		void *(__cdecl * n)(void) = (void *(__cdecl *)(void))sym("SteamAPI_SteamNetworkingUtils_SteamAPI_v004");
		void *(__cdecl * mm)(void) = (void *(__cdecl *)(void))sym("SteamAPI_SteamMatchmaking_v009");
		if (g_symMissing)
			return 0;
		SetEnvironmentVariableA("SteamAppId", "13520"); // as Steam sets it when it starts Far Cry
		SetEnvironmentVariableA("SteamGameId", "13520");
		err[0] = 0;
		if (InitFlat(err)) {
			logf("steam: Steam did not start (%s), Steam off", err);
			return 0;
		}
		DispatchInit();
		g_pipe = GetPipe();
		g_user = u();
		g_friends = f();
		g_msgs = m();
		g_utils = n();
		g_mm = mm();
		if (!g_user || !g_friends || !g_msgs || !g_utils || !g_mm) {
			logf("steam: a Steam interface is missing, Steam off");
			return 0;
		}
	}
	InitRelay(g_utils); // fetch the relay network now, not on the first Join
	return 1;
}

// ---- sockets ----
static Addr addr(DWORD ip, int port) // ip and port in host order
{
	Addr a;
	memset(&a, 0, sizeof a);
	a.family = 2; // AF_INET
	a.port = (WORD)(((port & 0xff) << 8) | ((port >> 8) & 0xff));
	a.ip = ((ip & 0xff) << 24) | ((ip & 0xff00) << 8) | ((ip >> 8) & 0xff00) | (ip >> 24);
	return a;
}
#define LOCALHOST 0x7f000001
static SOCKET udp(int port) // on 127.0.0.1, non-blocking; -1 if the port is taken
{
	SOCKET s = pSocket(2, 2, 17); // AF_INET, SOCK_DGRAM, IPPROTO_UDP
	Addr a = addr(LOCALHOST, port);
	DWORD on = 1;
	if (s == (SOCKET)-1)
		return s;
	if (pBind(s, &a, sizeof a)) {
		pClose(s);
		return (SOCKET)-1;
	}
	pIoctl(s, 0x8004667e, &on); // FIONBIO
	return s;
}

// ---- tunnel (Steam thread) ----
static int g_up;                   // a Far Cry server runs in this process
static U64 g_me, g_host;           // client: the host we joined
static SOCKET g_game = (SOCKET)-1;  // client: 127.0.0.1:49011
static SOCKET g_loopS = (SOCKET)-1; // loop: our fake Steam socket
static Addr g_gameAddr;
static int g_gameKnown;
static struct { U64 id; SOCKET s; DWORD last; } g_peers[MAX_PEERS]; // host: one per remote player
static BYTE g_buf[65536];
static U64 g_ownLobby;              // host: the lobby we created (its members may connect)
static U64 g_inLobby, g_waitLobby;  // client: the lobby we entered; entered, waiting for its server
static U64 g_callCreate, g_callList, g_callJoin;
static char g_kv[300];              // host: key=value pairs for the lobby being created
static U64 g_rows[MAX_ROWS];
static int g_nRows;

static void sendSteam(U64 to, const BYTE *data, int n)
{
	Identity id;
	if (g_sLoop) {
		Addr a = addr(LOCALHOST, (int)LO(to));
		pSendTo(g_loopS, (const char *)data, n, 0, &a, sizeof a);
		return;
	}
	memset(&id, 0, sizeof id);
	id.type = 16; // k_ESteamNetworkingIdentityType_SteamID
	id.size = 8;
	id.u.steamID = to;
	SendToUser(g_msgs, &id, data, (DWORD)n, SEND_FLAGS, 0);
}
static void hostReceived(U64 from, const BYTE *data, int n) // remote game -> our server
{
	Addr server = addr(LOCALHOST, SV_PORT);
	int i, free = -1;
	if (!g_up)
		return;
	for (i = 0; i < MAX_PEERS; i++) {
		if (g_peers[i].s != (SOCKET)-1 && g_peers[i].id == from)
			break;
		if (free < 0 && g_peers[i].s == (SOCKET)-1)
			free = i;
	}
	if (i == MAX_PEERS) {
		if (free < 0)
			return;
		i = free;
		if ((g_peers[free].s = udp(0)) == (SOCKET)-1)
			return; // no local socket: the slot stays free
		g_peers[i].id = from;
		say("player %x%08x joins", HI(from), LO(from));
	}
	g_peers[i].last = GetTickCount();
	pSendTo(g_peers[i].s, (const char *)data, n, 0, &server, sizeof server);
}
static void received(U64 from, const BYTE *data, int n)
{
	if (g_host && from == g_host) { // host's server -> our game
		if (g_gameKnown)
			pSendTo(g_game, (const char *)data, n, 0, &g_gameAddr, sizeof g_gameAddr);
	} else
		hostReceived(from, data, n);
}
static void pump(void) // move every waiting packet once
{
	int i, n, len;
	void *msgs[32];
	Addr from;
	for (i = 0; i < MAX_PEERS; i++) {
		if (g_peers[i].s == (SOCKET)-1)
			continue;
		while ((n = pRecvFrom(g_peers[i].s, (char *)g_buf, sizeof g_buf, 0, 0, 0)) > 0)
			sendSteam(g_peers[i].id, g_buf, n);
		if (GetTickCount() - g_peers[i].last > PEER_IDLE) {
			say("player %x%08x left", HI(g_peers[i].id), LO(g_peers[i].id));
			pClose(g_peers[i].s);
			g_peers[i].s = (SOCKET)-1;
		}
	}
	if (g_game != (SOCKET)-1 && g_host) {
		len = sizeof g_gameAddr;
		while ((n = pRecvFrom(g_game, (char *)g_buf, sizeof g_buf, 0, &g_gameAddr, &len)) > 0) {
			g_gameKnown = 1;
			sendSteam(g_host, g_buf, n);
			len = sizeof g_gameAddr;
		}
	}
	if (g_sLoop) {
		if (g_loopS == (SOCKET)-1)
			return;
		len = sizeof from;
		while ((n = pRecvFrom(g_loopS, (char *)g_buf, sizeof g_buf, 0, &from, &len)) > 0) {
			received((U64)(((from.port & 0xff) << 8) | ((from.port >> 8) & 0xff)), g_buf, n);
			len = sizeof from;
		}
		return;
	}
	while ((n = Receive(g_msgs, 0, msgs, 32)) > 0)
		for (i = 0; i < n; i++) {
			received(MSG_FROM(msgs[i]), MSG_DATA(msgs[i]), MSG_SIZE(msgs[i]));
			Release(msgs[i]);
		}
}

static void join(U64 host)
{
	char line[100];
	int port[1];
	if (g_up) {
		say("this game runs a server: leave it before joining another");
		return;
	}
	if (g_game == (SOCKET)-1 && (g_game = udp(CL_PORT)) == (SOCKET)-1) {
		say("UDP port %d is taken: is FarCryCoopSteam.exe or another game running?", CL_PORT);
		return;
	}
	if (g_sLoop && g_loopS == (SOCKET)-1) {
		int p;
		for (p = LOOP_HOST + 1; p < LOOP_HOST + 17 && (g_loopS = udp(p)) == (SOCKET)-1; p++)
			;
	}
	g_host = host;
	g_gameKnown = 0;
	port[0] = CL_PORT;
	// as the LAN server list: late switch, no CD key check (that one crashed the game)
	wvsprintfA(line, "#Game:Connect(\"127.0.0.1:%d\",1)", (va_list)port);
	runOnMain(line);
	say("joining %x%08x", HI(host), LO(host));
}

static U64 parseHex(const char *s)
{
	U64 v = 0;
	for (; *s; s++) {
		int d = *s >= '0' && *s <= '9' ? *s - '0' : *s >= 'a' && *s <= 'f' ? *s - 'a' + 10 : *s >= 'A' && *s <= 'F' ? *s - 'A' + 10 : -1;
		if (d < 0)
			break;
		v = (v << 4) | (U64)d;
	}
	return v;
}
static U64 parseDec(const char *s)
{
	U64 v = 0;
	for (; *s >= '0' && *s <= '9'; s++)
		v = (v << 3) + (v << 1) + (U64)(*s - '0'); // no CRT: v * 10 would call __allmul
	return v;
}
static int isMember(U64 who) // a member of our lobby (players who found it in the list)
{
	int i, n;
	if (!g_ownLobby)
		return 0;
	n = LobbyMembers(g_mm, g_ownLobby);
	for (i = 0; i < n; i++)
		if (LobbyMember(g_mm, g_ownLobby, i) == who)
			return 1;
	return 0;
}

static void leaveLobbies(void)
{
	if (g_ownLobby)
		LeaveLobby(g_mm, g_ownLobby);
	if (g_inLobby)
		LeaveLobby(g_mm, g_inLobby);
	g_ownLobby = g_inLobby = g_waitLobby = 0;
}
static void enterLobby(U64 lobby) // a lobby from the list or a Steam invite
{
	if (g_up) {
		say("this game runs a server: leave it before joining another");
		return;
	}
	if (g_callJoin)
		return;
	leaveLobbies();
	g_callJoin = JoinLobby(g_mm, lobby);
}
static void lobbyEntered(U64 lobby)
{
	g_inLobby = g_waitLobby = lobby;
	say("in lobby %x%08x", HI(lobby), LO(lobby));
}
static void lobbyWait(void) // client: join the lobby's server once it runs
{
	const char *up, *host;
	if (!g_waitLobby)
		return;
	up = GetLobbyData(g_mm, g_waitLobby, "up");
	// "host", not the lobby owner: when the host leaves, Steam makes another member the owner
	host = GetLobbyData(g_mm, g_waitLobby, "host");
	if (up && up[0] == '1' && host && host[0]) {
		g_waitLobby = 0;
		join(parseHex(host));
	}
}

static void listRows(int count)
{
	int i;
	g_nRows = count < MAX_ROWS ? count : MAX_ROWS;
	say("%d game(s)", count);
	for (i = 0; i < g_nRows; i++) {
		U64 l = g_rows[i] = LobbyByIndex(g_mm, i);
		void *a[6];
		static char line[1100]; // wvsprintfA writes up to 1024; the strings are other players' (up to 8 KB): cut
		a[0] = (void *)i;
		a[1] = (void *)GetLobbyData(g_mm, l, "name");
		a[2] = (void *)GetLobbyData(g_mm, l, "map");
		a[3] = (void *)LobbyMembers(g_mm, l);
		a[4] = (void *)LobbyLimit(g_mm, l);
		a[5] = (void *)GetLobbyData(g_mm, l, "up");
		wvsprintfA(line, "%d: %.48s | %.32s | %d/%d | up=%.1s", (va_list)a);
		say("%s", line);
	}
}

static void setLobbyData(void) // host: the player's key=value pairs, then ours (they win)
{
	static char id[20];
	DWORD h[2];
	char *p = g_kv, *k, *v;
	while (*p) {
		while (*p == '|')
			p++;
		k = p;
		while (*p && *p != '=' && *p != '|')
			p++;
		if (*p != '=')
			continue;
		*p++ = 0;
		v = p;
		while (*p && *p != '|')
			p++;
		if (*p)
			*p++ = 0;
		SetLobbyData(g_mm, g_ownLobby, k, v);
	}
	g_kv[0] = 0;
	h[0] = HI(g_me);
	h[1] = LO(g_me);
	wvsprintfA(id, "%x%08x", (va_list)h);
	SetLobbyData(g_mm, g_ownLobby, "fc1coop", NET_KEY);
	SetLobbyData(g_mm, g_ownLobby, "host", id);
	SetLobbyData(g_mm, g_ownLobby, "up", g_up ? "1" : "0");
}
static void lobbyFailed(const char *why)
{
	say("lobby not created: %s", why);
	runOnMain("#if CoopSteam_OnLobby then CoopSteam_OnLobby(0) end");
}

static void callbacks(void)
{
	CallbackMsg cb;
	static BYTE res[64];
	BYTE failed;
	RunFrame(g_pipe);
	while (NextCallback(g_pipe, &cb)) {
		if (cb.id == CB_CALL_DONE) {
			U64 call = *(U64 *)cb.param;
			failed = 0;
			if (call == g_callCreate) {
				g_callCreate = 0;
				if (CallResult(g_pipe, call, res, 16, CB_LOBBY_CREATED, &failed) && !failed && *(int *)res == 1) {
					g_ownLobby = *(U64 *)(res + 8);
					say("lobby %x%08x created", HI(g_ownLobby), LO(g_ownLobby));
					setLobbyData();
					runOnMain("#if CoopSteam_OnLobby then CoopSteam_OnLobby(1) end");
				} else
					lobbyFailed("Steam said no (offline?)");
			} else if (call == g_callList) {
				g_callList = 0;
				if (CallResult(g_pipe, call, res, 4, CB_LOBBY_LIST, &failed) && !failed)
					listRows(*(int *)res);
				else
					say("lobby list failed");
			} else if (call == g_callJoin) {
				g_callJoin = 0;
				if (!CallResult(g_pipe, call, res, 24, CB_LOBBY_ENTER, &failed) || failed)
					say("could not enter the lobby");
				else if (*(DWORD *)(res + 16) != 1) // EChatRoomEnterResponse
					say("could not enter the lobby (response %d)", *(DWORD *)(res + 16));
				else
					lobbyEntered(*(U64 *)res);
			}
		} else if (cb.id == CB_SESSION_REQUEST) {
			// host: only while we host, and only Steam friends (k_EFriendFlagImmediate) or members of
			// our lobby: a stranger who learned our SteamID gets no session, no packet reaches the
			// server. A public lobby lets anyone in the world list become a member (owner's choice:
			// public games); an accepted session is not checked again. Client: our own host (its
			// session broke and it sent first).
			const Identity *who = (const Identity *)cb.param;
			if (who->type == 16 && ((g_up && (HasFriend(g_friends, who->u.steamID, 4) || isMember(who->u.steamID))) ||
			                        (g_host && who->u.steamID == g_host)))
				AcceptSession(g_msgs, who);
			else
				say("session from %x%08x refused: not a friend or lobby member, or no server", HI(who->u.steamID), LO(who->u.steamID));
		} else if (cb.id == CB_JOIN_REQUESTED) {
			const char *c = (const char *)cb.param + 8;
			if (starts(c, "+coop ")) // "+coop <hex SteamID>"
				join(parseHex(c + 6));
		} else if (cb.id == CB_LOBBY_JOIN_REQ)
			enterLobby(*(U64 *)cb.param);
		FreeCallback(g_pipe);
	}
}

static int serverUp(void) // this process holds UDP 49001 (listen host)
{
	static DWORD tbl[8192];
	DWORD size = sizeof tbl, i, pid = GetCurrentProcessId();
	if (!pUdpTable || pUdpTable(tbl, &size, 0, 2, 1, 0)) // AF_INET, UDP_TABLE_OWNER_PID
		return g_up;
	for (i = 0; i < tbl[0] && i < (sizeof tbl / 4 - 1) / 3; i++) { // rows: addr, port (network order), pid
		DWORD port = tbl[2 + i * 3] & 0xffff;
		if (((port & 0xff) << 8 | port >> 8) == SV_PORT && tbl[3 + i * 3] == pid)
			return 1;
	}
	return 0;
}

static void command(char *c) // a "coop_steam ..." line
{
	if (starts(c, "status")) {
		void *a[4];
		a[0] = g_sLoop ? (void *)"loop (no Steam)" : (void *)PersonaName(g_friends);
		a[1] = g_up ? (void *)"host" : g_host ? (void *)"client" : (void *)"idle";
		a[2] = (void *)(g_sLoop ? 100 : RelayStatus(g_utils, 0));
		a[3] = (void *)LO(g_ownLobby ? g_ownLobby : g_inLobby);
		{
			static char line[1100];
			wvsprintfA(line, "%.64s, %s, relay %d (100 = ready), lobby %x", (va_list)a);
			say("%s", line);
		}
	} else if (starts(c, "join ")) { // join <hex>|loop
		join(starts(c + 5, "loop") ? (U64)LOOP_HOST : parseHex(c + 5));
	} else if (g_sLoop) {
		say("loop: only status and join work");
	} else if (starts(c, "host")) { // host <max>|key=value|...
		int max = 0, i;
		char *p = c + 4;
		while (*p == ' ')
			p++;
		while (*p >= '0' && *p <= '9')
			max = max * 10 + *p++ - '0';
		if (g_callCreate) {
			say("a lobby is being created already");
			return;
		}
		leaveLobbies();
		for (i = 0; i < 299 && p[i]; i++) // set once Steam has created it (callbacks)
			g_kv[i] = p[i];
		g_kv[i] = 0;
		if (!(g_callCreate = CreateLobby(g_mm, 2, max > 0 && max <= 16 ? max : 4))) // k_ELobbyTypePublic
			lobbyFailed("no Steam call (offline?)");
	} else if (starts(c, "find")) {
		StrFilter(g_mm, "fc1coop", NET_KEY, 0); // k_ELobbyComparisonEqual
		DistFilter(g_mm, 3);                     // worldwide
		g_callList = RequestList(g_mm);
	} else if (starts(c, "joinlobby")) { // joinlobby <n>
		int n = 0;
		char *p = c + 9;
		while (*p == ' ')
			p++;
		while (*p >= '0' && *p <= '9')
			n = n * 10 + *p++ - '0';
		if (n < g_nRows)
			enterLobby(g_rows[n]);
		else
			say("no game %d: run coop_steam find first", n);
	} else if (starts(c, "leave")) {
		leaveLobbies();
		say("left the lobby");
	} else if (starts(c, "invite")) {
		if (g_ownLobby)
			InviteDialog(g_friends, g_ownLobby); // the Steam overlay: only when Steam started the game
		else
			say("create a lobby first: coop_steam host");
	} else
		say("coop_steam status | join <SteamID>|loop | host <max>|key=value|... | find | joinlobby <n> | leave | invite");
}

static DWORD __stdcall steamThread(void *dll)
{
	static char c[300];
	BYTE wsa[400];
	DWORD check = 0, id[2];
	HANDLE ws = LoadLibraryA("ws2_32.dll"), ip = LoadLibraryA("iphlpapi.dll");
	int i;
	pWSAStartup = (int(__stdcall *)(WORD, void *))GetProcAddress(ws, "WSAStartup");
	pSocket = (SOCKET(__stdcall *)(int, int, int))GetProcAddress(ws, "socket");
	pBind = (int(__stdcall *)(SOCKET, const void *, int))GetProcAddress(ws, "bind");
	pClose = (int(__stdcall *)(SOCKET))GetProcAddress(ws, "closesocket");
	pIoctl = (int(__stdcall *)(SOCKET, long, DWORD *))GetProcAddress(ws, "ioctlsocket");
	pRecvFrom = (int(__stdcall *)(SOCKET, char *, int, int, void *, int *))GetProcAddress(ws, "recvfrom");
	pSendTo = (int(__stdcall *)(SOCKET, const char *, int, int, const void *, int))GetProcAddress(ws, "sendto");
	pUdpTable = ip ? (DWORD(__stdcall *)(void *, DWORD *, BOOL, DWORD, int, DWORD))GetProcAddress(ip, "GetExtendedUdpTable") : 0;
	if (!pWSAStartup || !pSendTo) {
		logf("steam: no ws2_32, Steam off");
		g_sOff = 1;
		return 0;
	}
	pWSAStartup(0x0202, wsa);
	for (i = 0; i < MAX_PEERS; i++)
		g_peers[i].s = (SOCKET)-1;
	if (!g_sLoop && !steamInit((const char *)dll)) {
		g_sOff = 1;
		return 0;
	}
	timeBeginPeriod(1); // Sleep(1) below is 1 ms, not a 15.6 ms timer tick
	g_me = g_sLoop ? LOOP_HOST : GetSteamID(g_user);
	id[0] = HI(g_me);
	id[1] = LO(g_me);
	g_sOn = 1;
	if (g_sLoop)
		say("loop: the tunnel runs over 127.0.0.1, no Steam");
	else
		say("Steam: %s (%x%08x), Far Cry AppID 13520", PersonaName(g_friends), id[0], id[1]);
	{ // started by Steam from Join: "+coop <hex>" (rich presence) or "+connect_lobby <id>"
		char *cmd = GetCommandLineA();
		for (; *cmd; cmd++)
			if (starts(cmd, "+coop "))
				join(parseHex(cmd + 6));
			else if (!g_sLoop && starts(cmd, "+connect_lobby "))
				enterLobby(parseDec(cmd + 15));
	}
	for (;;) {
		while (qGet(g_inQ, 8, g_inHead, &g_inTail, c))
			command(c);
		if (GetTickCount() - check > 2000) {
			int now = serverUp();
			check = GetTickCount();
			if (now != g_up) {
				g_up = now;
				if (g_sLoop) {
					if (g_up && g_loopS == (SOCKET)-1 && (g_loopS = udp(LOOP_HOST)) == (SOCKET)-1)
						say("loop port %d is taken", LOOP_HOST);
				} else if (g_up) {
					static char connect[40];
					wvsprintfA(connect, "+coop %x%08x", (va_list)id);
					SetRichPresence(g_friends, "status", "Far Cry co-op host");
					SetRichPresence(g_friends, "connect", connect);
				} else
					ClearRichPresence(g_friends);
				if (g_ownLobby)
					SetLobbyData(g_mm, g_ownLobby, "up", g_up ? "1" : "0");
				say(g_up ? "server up: players can join" : "no server in this game");
			}
			if (!g_sLoop)
				lobbyWait();
		}
		if (!g_sLoop)
			callbacks();
		pump();
		Sleep(1);
	}
}

// From steamJoin (worker thread, IGame is up): Steam on if its DLL (or the loop file) is there.
static void steamStart(void)
{
	static char dll[600], loop[600];
	int n = 0, i;
	void *sys, *con, **slot;
	DWORD old;
	HANDLE f;
	while (g_join[n])
		n++;
	while (n > 0 && g_join[n - 1] != '\\') // g_join = ...\Mods\FarCryCoop\join.txt
		n--;
	for (i = 0; i < n; i++)
		dll[i] = loop[i] = g_join[i];
	wvsprintfA(dll + n, "Steam\\steam_api.dll", 0);
	wvsprintfA(loop + n, "steam_loop.txt", 0);
	f = CreateFileA(loop, 0x80000000, 1, 0, 3, 0x80, 0);
	if (f != (HANDLE)-1) {
		CloseHandle(f);
		g_sLoop = 1;
	} else {
		f = CreateFileA(dll, 0x80000000, 1, 0, 3, 0x80, 0);
		if (f == (HANDLE)-1) {
			logf("steam: no %s, Steam off", dll);
			return;
		}
		CloseHandle(f);
	}
	InitializeCriticalSection(g_sCs);
	sys = getISystem();
	con = sys ? ((void *(__fastcall *)(void *, void *))VFN(sys, 0x60))(sys, 0) : 0;
	if (!con) {
		logf("steam: no console, Steam off");
		return;
	}
	slot = &(*(void ***)con)[0x80 / 4]; // IConsole::ExecuteString
	oExec = (void(__fastcall *)(void *, void *, const char *, int, int)) * slot;
	VirtualProtect(slot, 4, 0x04, &old);
	*slot = (void *)hExec;
	VirtualProtect(slot, 4, old, &old);
	CreateThread(0, 0, steamThread, dll, 0, 0);
}
