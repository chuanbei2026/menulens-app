import Foundation

/// Simplified characters that slip into a Traditional Chinese translation,
/// replaced by their Traditional form. Models asked for Traditional Chinese
/// still write the odd Simplified character (gpt-4.1: 酸橘汁腌魚; Mistral:
/// 洋蓟), most often in food words they have mostly seen in Simplified.
///
/// Character by character, and ONLY characters with exactly one Traditional
/// form that are never themselves Traditional: 鱼→魚, 鸡→雞, 酱→醬. ICU's
/// "Hans-Hant" transform was tried and rejected — it also rewrites correct
/// Traditional text where one Simplified character has several Traditional
/// forms (干貝→乾貝, 鄧杰→鄧傑, the surname 范→範, 了解→瞭解). Those
/// ambiguous characters (干 发 面 后 里 云 …) are left alone.
///
/// The table is OpenCC's STCharacters restricted to single-candidate entries
/// whose source is in GB2312 and is not a key of TSCharacters, with targets
/// in their Taiwan form (TWVariants: 爲→為, 啓→啟; characters that are
/// already Taiwan-standard, like 秘 群 床, dropped), plus `overrides`. No
/// target is also a source, so the mapping is idempotent.
enum TraditionalChinese {
    static func fixingSimplified(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { map[$0] != nil }) else { return text }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.map { map[$0] ?? $0 })
        return String(scalars)
    }

    private static let map: [Unicode.Scalar: Unicode.Scalar] = {
        var map: [Unicode.Scalar: Unicode.Scalar] = [:]
        let scalars = Array((pairs + overrides).unicodeScalars)
        for i in stride(from: 0, to: scalars.count - 1, by: 2) {
            map[scalars[i]] = scalars[i + 1]
        }
        return map
    }()

    /// Characters OpenCC lists with several Traditional forms, where a menu
    /// means one: 腌 is also a (rare) Traditional character, but on a menu it
    /// is always 醃 "pickled, marinated".
    private static let overrides = "腌醃"

    /// Simplified/Traditional pairs, two characters each.
    private static let pairs = """
        与與专專业業丛叢东東丝絲丢丟两兩严嚴丧喪临臨为為丽麗举舉义義乌烏乐樂乔喬习習乡鄉书書买買乱亂争爭亏虧亚亞产產亩畝亲親亵褻亿億仅僅
        从從仓倉仪儀们們众眾优優会會伛傴伞傘伟偉传傳伤傷伥倀伦倫伧傖伪偽伫佇体體佥僉侠俠侣侶侥僥侦偵侧側侨僑侩儈侪儕侬儂俣俁俦儔俨儼俩倆
        俪儷俭儉债債倾傾偬傯偻僂偾僨偿償傥儻傧儐储儲傩儺儿兒兑兌兖兗兰蘭关關兴興兹茲养養兽獸冁囅内內冈岡册冊写寫军軍农農冯馮决決况況冻凍
        净淨凉涼减減凑湊凛凜凤鳳凫鳧凭憑凯凱击擊凿鑿刍芻刘劉则則刚剛创創删刪刭剄刹剎刽劊刿劌剀剴剂劑剐剮剑劍剥剝剧劇劝勸办辦务務劢勱动動
        励勵劲勁劳勞势勢匀勻匦匭匮匱区區医醫华華协協单單卖賣卢盧卧臥卫衛却卻卺巹厅廳厉厲压壓厌厭厍厙厕廁厢廂厣厴厦廈厨廚厩廄厮廝县縣叁叄
        双雙变變叙敘叠疊号號叽嘰吓嚇吕呂吗嗎吨噸听聽启啟吴吳呐吶呒嘸呓囈呕嘔呖嚦呗唄员員呙咼呛嗆呜嗚咏詠咙嚨咛嚀咝噝咤吒响響哑啞哒噠哓嘵
        哔嗶哕噦哙噲哜嚌哝噥哟喲唛嘜唠嘮唢嗩唤喚啧嘖啬嗇啭囀啸嘯喷噴喽嘍喾嚳嗫囁嗳噯嘘噓嘤嚶嘱囑噜嚕嚣囂园園囱囪围圍囵圇国國图圖圆圓圣聖
        圹壙场場块塊坚堅坜壢坞塢坟墳坠墜垄壟垅壠垆壚垒壘垦墾垩堊垫墊垭埡垲塏垴堖埘塒埚堝堑塹堕墮墙牆壮壯声聲壳殼壶壺处處备備够夠头頭夺奪
        奁奩奂奐奋奮奖獎奥奧妆妝妇婦妈媽妩嫵妪嫗妫媯姗姍姹奼娄婁娅婭娆嬈娇嬌娈孌娱娛娲媧婴嬰婵嬋婶嬸媪媼嫒嬡嫔嬪嫱嬙嬷嬤孙孫学學孪孿宝寶
        实實宠寵审審宪憲宫宮宽寬宾賓寝寢对對寻尋导導寿壽将將尔爾尘塵尧堯尴尷层層屉屜届屆属屬屡屢屦屨屿嶼岁歲岂豈岖嶇岗崗岘峴岚嵐岛島岭嶺
        岽崬岿巋峄嶧峡峽峤嶠峥崢峦巒崂嶗崃崍崭嶄嵘嶸嵝嶁巅巔巩鞏巯巰币幣帅帥师師帏幃帐帳帜幟带帶帧幀帮幫帱幬帻幘帼幗幂冪庄莊庆慶庐廬庑廡
        库庫应應庙廟庞龐废廢廪廩开開异異弃棄弑弒张張弪弳弯彎弹彈强強归歸彦彥彻徹徕徠忆憶忏懺忧憂忾愾怀懷态態怂慫怃憮怄慪怅悵怆愴怜憐总總
        怼懟怿懌恋戀恒恆恳懇恸慟恹懨恺愷恻惻恼惱恽惲悦悅悫愨悬懸悭慳悯憫惊驚惧懼惨慘惩懲惫憊惬愜惭慚惮憚惯慣愠慍愤憤愦憒慑懾懑懣懒懶懔懍
        戆戇戋戔戏戲戗戧战戰戬戩户戶扑撲执執扩擴扪捫扫掃扬揚扰擾抚撫抛拋抟摶抠摳抡掄抢搶护護报報担擔拟擬拢攏拣揀拥擁拦攔拧擰拨撥择擇挚摯
        挛攣挝撾挞撻挟挾挠撓挡擋挢撟挣掙挤擠挥揮捞撈损損捡撿换換捣搗掳擄掴摑掷擲掸撣掺摻掼摜揽攬揿撳搀攙搁擱搂摟搅攪携攜摄攝摅攄摇搖摈擯
        摊攤撄攖撑撐撵攆撷擷撸擼撺攛擞擻攒攢敌敵敛斂数數斋齋斓斕斩斬断斷无無旧舊时時旷曠昙曇昵暱昼晝显顯晋晉晒曬晓曉晔曄晕暈晖暉暂暫暧曖
        机機杀殺杂雜权權条條来來杨楊杩榪构構枞樅枢樞枣棗枥櫪枧梘枨棖枫楓枭梟柠檸柽檉栀梔栅柵标標栈棧栉櫛栊櫳栋棟栌櫨栎櫟栏欄树樹栖棲样樣
        栾欒桠椏桡橈桢楨档檔桤榿桥橋桦樺桧檜桨槳桩樁梦夢检檢棂欞椁槨椟櫝椠槧椤欏椭橢楼樓榄欖榇櫬榈櫚榉櫸槛檻槟檳槠櫧横橫樯檣樱櫻橥櫫橱櫥
        橹櫓橼櫞檩檁欢歡欤歟欧歐歼殲殁歿殇殤残殘殒殞殓殮殚殫殡殯殴毆毂轂毕畢毙斃毡氈毵毿氇氌气氣氢氫氩氬氲氳汉漢汤湯汹洶沟溝没沒沣灃沤漚
        沥瀝沦淪沧滄沩溈沪滬泞濘泪淚泶澩泷瀧泸瀘泺濼泻瀉泼潑泽澤泾涇洁潔洒灑洼窪浃浹浅淺浆漿浇澆浈湞浊濁测測浍澮济濟浏瀏浑渾浒滸浓濃浔潯
        涛濤涝澇涞淶涟漣涠潿涡渦涣渙涤滌润潤涧澗涨漲涩澀渊淵渌淥渍漬渎瀆渐漸渑澠渔漁渖瀋渗滲温溫湾灣湿溼溃潰溅濺溆漵滗潷滚滾滞滯滠灄满滿
        滢瀅滤濾滥濫滦灤滨濱滩灘潆瀠潇瀟潋瀲潍濰潜潛潴瀦澜瀾濑瀨濒瀕灏灝灭滅灯燈灵靈灾災灿燦炀煬炉爐炖燉炜煒炝熗点點炽熾烁爍烂爛烃烴烛燭
        烦煩烧燒烨燁烩燴烫燙烬燼热熱焕煥焖燜焘燾爱愛爷爺牍牘牦犛牵牽牺犧犊犢状狀犷獷犸獁犹猶狈狽狞獰独獨狭狹狮獅狯獪狰猙狱獄狲猻猃獫猎獵
        猕獼猡玀猪豬猫貓猬蝟献獻獭獺玑璣玛瑪玮瑋环環现現玺璽珐琺珑瓏珲琿琏璉琐瑣琼瓊瑶瑤瑷璦璎瓔瓒瓚瓮甕瓯甌电電画畫畅暢畴疇疖癤疗療疟瘧
        疠癘疡瘍疬癧疮瘡疯瘋疱皰疴痾痈癰痉痙痒癢痖瘂痨癆痪瘓痫癇瘅癉瘗瘞瘘瘻瘪癟瘫癱瘾癮瘿癭癞癩癣癬癫癲皑皚皱皺皲皸盏盞盐鹽监監盖蓋盗盜
        盘盤眍瞘眦眥睁睜睐睞睑瞼瞒瞞瞩矚矫矯矶磯矾礬矿礦砀碭码碼砖磚砗硨砚硯砜碸砺礪砻礱砾礫础礎硕碩硖硤硗磽碍礙碛磧碜磣碱鹼礼禮祢禰祯禎
        祷禱祸禍禀稟禄祿禅禪离離秃禿秆稈积積称稱秽穢稆穭税稅稣穌稳穩穑穡穷窮窃竊窍竅窑窯窜竄窝窩窥窺窦竇窭窶竖豎竞競笃篤笋筍笔筆笕筧笺箋
        笼籠笾籩筚篳筛篩筝箏筹籌简簡箦簀箧篋箨籜箩籮箪簞箫簫篑簣篓簍篮籃篱籬簖籪籁籟籴糴类類籼秈粜糶粝糲粤粵粪糞粮糧糁糝糇餱糍餈紧緊絷縶
        纟糹纠糾纡紆红紅纣紂纥紇约約级級纨紈纩纊纪紀纫紉纬緯纭紜纯純纰紕纱紗纲綱纳納纵縱纶綸纷紛纸紙纹紋纺紡纽紐纾紓线線绀紺绁紲绂紱练練
        组組绅紳细細织織终終绉縐绊絆绋紼绌絀绍紹绎繹经經绐紿绑綁绒絨结結绔絝绕繞绗絎绘繪给給绚絢绛絳络絡绝絕绞絞统統绠綆绡綃绢絹绣繡绥綏
        绦絛继繼绨綈绩績绪緒绫綾续續绮綺绯緋绰綽绲緄绳繩维維绵綿绶綬绸綢绺綹绻綣综綜绽綻绾綰绿綠缀綴缁緇缂緙缃緗缄緘缅緬缆纜缇緹缈緲缉緝
        缋繢缌緦缍綞缎緞缏緶缑緱缒縋缓緩缔締缕縷编編缗緡缘緣缙縉缚縛缛縟缜縝缝縫缟縞缠纏缡縭缢縊缣縑缤繽缥縹缦縵缧縲缨纓缩縮缪繆缫繅缬纈
        缭繚缮繕缯繒缰韁缱繾缲繰缳繯缴繳缵纘罂罌网網罗羅罚罰罢罷罴羆羁羈羟羥羡羨翘翹耢耮耧耬耸聳耻恥聂聶聋聾职職聍聹联聯聩聵聪聰肃肅肠腸
        肤膚肮骯肴餚肾腎肿腫胀脹胁脅胆膽胧朧胨腖胪臚胫脛胶膠脉脈脍膾脐臍脑腦脓膿脔臠脚腳脱脫脶腡脸臉腭顎腻膩腼靦腽膃腾騰膑臏舆輿舣艤舰艦
        舱艙舻艫艰艱艺藝节節芈羋芗薌芜蕪芦蘆苁蓯苇葦苈藶苋莧苌萇苍蒼苎苧茎莖茏蘢茑蔦茔塋茕煢茧繭荆荊荚莢荛蕘荜蓽荞蕎荟薈荠薺荣榮荤葷荥滎
        荦犖荧熒荨蕁荩藎荪蓀荬蕒荭葒荮葤莅蒞莱萊莲蓮莳蒔莴萵莶薟莸蕕莹瑩莺鶯莼蓴萝蘿萤螢营營萦縈萧蕭萨薩葱蔥蒇蕆蒉蕢蒋蔣蒌蔞蓝藍蓟薊蓠蘺
        蓣蕷蓥鎣蓦驀蔷薔蔹蘞蔺藺蔼藹蕲蘄蕴蘊薮藪藓蘚蘖櫱虏虜虑慮虚虛虬虯虮蟣虱蝨虽雖虾蝦虿蠆蚀蝕蚁蟻蚂螞蚕蠶蚬蜆蛊蠱蛎蠣蛏蟶蛮蠻蛰蟄蛱蛺
        蛲蟯蛳螄蛴蠐蜕蛻蜗蝸蝇蠅蝈蟈蝉蟬蝼螻蝾蠑螨蟎衅釁衔銜补補衬襯衮袞袄襖袜襪袭襲装裝裆襠裢褳裣襝裤褲褛褸褴襤见見观觀规規觅覓视視觇覘
        览覽觉覺觊覬觋覡觌覿觎覦觏覯觐覲觑覷觞觴触觸觯觶誉譽誊謄讠訁计計订訂讣訃认認讥譏讦訐讧訌讨討让讓讪訕讫訖训訓议議讯訊记記讲講讳諱
        讴謳讵詎讶訝讷訥许許讹訛论論讼訟讽諷设設访訪诀訣诂詁诃訶评評诅詛识識诈詐诉訴诊診诋詆诌謅词詞诎詘诏詔译譯诒詒诓誆诔誄试試诖詿诗詩
        诘詰诙詼诚誠诛誅诜詵话話诞誕诟詬诠詮诡詭询詢诣詣诤諍该該详詳诧詫诨諢诩詡诫誡诬誣语語诮誚误誤诰誥诱誘诲誨诳誑说說诵誦诶誒请請诸諸
        诹諏诺諾读讀诼諑诽誹课課诿諉谀諛谁誰谂諗调調谄諂谅諒谆諄谇誶谈談谊誼谋謀谌諶谍諜谎謊谏諫谐諧谑謔谒謁谓謂谔諤谕諭谖諼谗讒谘諮谙諳
        谚諺谛諦谜謎谝諞谟謨谠讜谡謖谢謝谣謠谤謗谦謙谧謐谨謹谩謾谪謫谫譾谬謬谭譚谮譖谯譙谰讕谱譜谲譎谳讞谴譴谵譫谶讖贝貝贞貞负負贡貢财財
        责責贤賢败敗账賬货貨质質贩販贪貪贫貧贬貶购購贮貯贯貫贰貳贱賤贲賁贳貰贴貼贵貴贶貺贷貸贸貿费費贺賀贻貽贼賊贽贄贾賈贿賄赀貲赁賃赂賂
        赃贓资資赅賅赆贐赇賕赈賑赉賚赊賒赋賦赌賭赍齎赎贖赏賞赐賜赓賡赔賠赕賧赖賴赘贅赙賻赚賺赛賽赜賾赠贈赡贍赢贏赣贛赵趙赶趕趋趨趱趲趸躉
        跃躍跄蹌跞躒践踐跷蹺跸蹕跹躚跻躋踌躊踪蹤踬躓踯躑蹑躡蹒蹣蹰躕蹿躥躏躪躜躦躯軀车車轧軋轨軌轩軒轫軔转轉轭軛轮輪软軟轰轟轱軲轲軻轳轤
        轴軸轵軹轶軼轷軤轸軫轹轢轺軺轻輕轼軾载載轾輊轿轎辁輇辂輅较較辄輒辅輔辆輛辇輦辈輩辉輝辊輥辋輞辍輟辎輜辏輳辐輻辑輯输輸辔轡辕轅辖轄
        辗輾辘轆辙轍辚轔辞辭辩辯辫辮边邊辽遼达達迁遷过過迈邁运運还還这這进進远遠违違连連迟遲迩邇迳逕选選逊遜递遞逦邐逻邏遗遺遥遙邓鄧邝鄺
        邬鄔邮郵邹鄒邺鄴邻鄰郏郟郐鄶郑鄭郓鄆郦酈郧鄖郸鄲酝醞酱醬酽釅酾釃酿釀释釋銮鑾錾鏨钅釒钆釓钇釔钉釘钊釗钋釙钌釕钍釷钎釺钏釧钐釤钒釩
        钓釣钔鍆钕釹钗釵钙鈣钚鈈钛鈦钜鉅钝鈍钞鈔钠鈉钡鋇钢鋼钣鈑钤鈐钦欽钧鈞钨鎢钩鉤钪鈧钬鈥钭鈄钮鈕钯鈀钰鈺钱錢钲鉦钳鉗钴鈷钵缽钶鈳钷鉕
        钸鈽钹鈸钺鉞钼鉬钽鉭钾鉀钿鈿铀鈾铁鐵铂鉑铃鈴铄鑠铅鉛铆鉚铈鈰铉鉉铊鉈铋鉍铌鈮铍鈹铎鐸铐銬铑銠铒鉺铕銪铖鋮铗鋏铘鋣铙鐃铛鐺铜銅铝鋁
        铞銱铟銦铠鎧铡鍘铢銖铣銑铤鋌铥銩铧鏵铨銓铩鎩铪鉿铫銚铬鉻铭銘铮錚铯銫铰鉸铱銥铳銃铴鐋铵銨银銀铷銣铸鑄铹鐒铺鋪铼錸铽鋱铿鏗销銷锁鎖
        锂鋰锃鋥锅鍋锆鋯锇鋨锈鏽锉銼锊鋝锋鋒锌鋅锍鋶锎鐦锏鐧锐銳锑銻锒鋃锓鋟锔鋦锕錒锖錆锗鍺锘鍩错錯锚錨锛錛锝鍀锞錁锟錕锡錫锢錮锣鑼锤錘
        锥錐锦錦锨鍁锩錈锪鍃锬錟锭錠键鍵锯鋸锰錳锱錙锲鍥锴鍇锵鏘锶鍶锷鍔锸鍤锹鍬锺鍾锻鍛锼鎪锾鍰锿鎄镀鍍镁鎂镂鏤镄鐨镅鎇镆鏌镇鎮镉鎘镊鑷
        镌鐫镍鎳镏鎦镐鎬镑鎊镒鎰镓鎵镔鑌镖鏢镗鏜镘鏝镙鏍镛鏞镜鏡镝鏑镞鏃镟鏇镡鐔镣鐐镤鏷镥鑥镦鐓镧鑭镨鐠镩鑹镪鏹镫鐙镬鑊镭鐳镯鐲镱鐿镲鑔
        镳鑣镶鑲长長门門闩閂闪閃闫閆闭閉问問闯闖闰閏闱闈闳閎间間闵閔闶閌闷悶闸閘闹鬧闺閨闻聞闼闥闽閩闾閭阀閥阁閣阂閡阃閫阄鬮阅閱阆閬阈閾
        阉閹阊閶阋鬩阌閿阍閽阎閻阏閼阐闡阑闌阒闃阔闊阕闋阖闔阗闐阙闕阚闞队隊阳陽阴陰阵陣阶階际際陆陸陇隴陈陳陉陘陕陝陧隉陨隕险險随隨隐隱
        隶隸隽雋难難雏雛雠讎雳靂雾霧霁霽霉黴霭靄靓靚静靜靥靨鞑韃鞒鞽鞯韉鞲韝韦韋韧韌韩韓韪韙韫韞韬韜韵韻页頁顶頂顷頃顸頇项項顺順顼頊顽頑
        顾顧顿頓颀頎颁頒颂頌颃頏预預颅顱领領颇頗颈頸颉頡颊頰颌頜颍潁颏頦颐頤频頻颓頹颔頷颖穎颗顆题題颚顎颛顓颜顏额額颞顳颟顢颠顛颡顙颢顥
        颤顫颥顬颦顰颧顴风風飑颮飒颯飓颶飕颼飘飄飙飆飚飈飞飛飨饗餍饜饣飠饧餳饨飩饩餼饪飪饫飫饬飭饭飯饮飲饯餞饰飾饱飽饲飼饴飴饵餌饶饒饷餉
        饺餃饼餅饽餑饿餓馀餘馁餒馄餛馅餡馆館馇餷馈饋馊餿馋饞馍饃馏餾馐饈馑饉馒饅馓饊馔饌馕饢马馬驭馭驮馱驯馴驰馳驱驅驳駁驴驢驵駔驶駛驷駟
        驸駙驹駒驺騶驻駐驼駝驽駑驾駕驿驛骀駘骁驍骂罵骄驕骅驊骆駱骇駭骈駢骊驪骋騁验驗骏駿骐騏骑騎骒騍骓騅骖驂骗騙骘騭骚騷骛騖骜驁骝騮骞騫
        骟騸骠驃骡騾骢驄骣驏骤驟骥驥骧驤髅髏髋髖髌髕鬓鬢魇魘魉魎鱼魚鱿魷鲁魯鲂魴鲅鮁鲆鮃鲇鯰鲈鱸鲋鮒鲍鮑鲎鱟鲐鮐鲑鮭鲒鮚鲔鮪鲕鮞鲚鱭鲛鮫
        鲜鮮鲞鯗鲟鱘鲠鯁鲡鱺鲢鰱鲣鰹鲤鯉鲥鰣鲦鰷鲧鯀鲨鯊鲩鯇鲫鯽鲭鯖鲮鯪鲰鯫鲱鯡鲲鯤鲳鯧鲴鯝鲵鯢鲶鯰鲷鯛鲸鯨鲺鯴鲻鯔鲼鱝鲽鰈鳃鰓鳄鱷鳅鰍
        鳆鰒鳇鰉鳊鯿鳋鰠鳌鰲鳍鰭鳎鰨鳏鰥鳐鰩鳓鰳鳔鰾鳕鱈鳖鱉鳗鰻鳘鰵鳙鱅鳜鱖鳝鱔鳞鱗鳟鱒鳢鱧鸟鳥鸠鳩鸡雞鸢鳶鸣鳴鸥鷗鸦鴉鸨鴇鸩鴆鸪鴣鸫鶇
        鸬鸕鸭鴨鸯鴦鸱鴟鸲鴝鸳鴛鸵鴕鸶鷥鸷鷙鸸鴯鸹鴰鸺鵂鸽鴿鸾鸞鸿鴻鹁鵓鹂鸝鹃鵑鹄鵠鹅鵝鹆鵒鹈鵜鹉鵡鹊鵲鹋鶓鹌鵪鹎鵯鹏鵬鹑鶉鹕鶘鹗鶚鹘鶻
        鹚鷀鹛鶥鹜鶩鹞鷂鹣鶼鹤鶴鹦鸚鹧鷓鹨鷚鹩鷯鹪鷦鹫鷲鹬鷸鹭鷺鹰鷹鹱鸌鹳鸛鹾鹺麦麥麸麩黄黃黉黌黩黷黪黲黾黽鼋黿鼍鼉鼹鼴齐齊齑齏齿齒龀齔
        龃齟龄齡龅齙龆齠龇齜龈齦龉齬龊齪龋齲龌齷龙龍龚龔龛龕龟龜
        """
        .filter { !$0.isWhitespace }
}

extension MenuDocument {
    /// Every model-written (translated) string run through `transform`. The
    /// menu's own text — originals, prices, the restaurant name — is left
    /// alone: a Simplified Chinese menu must keep its Simplified original.
    func mappingTranslations(_ transform: (String) -> String) -> MenuDocument {
        MenuDocument(
            sourceLanguage: sourceLanguage,
            sourceLanguageChinese: transform(sourceLanguageChinese),
            restaurantName: restaurantName,
            sections: sections.map { section in
                MenuSection(
                    originalTitle: section.originalTitle,
                    chineseTitle: section.chineseTitle.map(transform),
                    bbox: section.bbox,
                    items: section.items.map { item in
                        MenuItemEntry(
                            originalName: item.originalName,
                            chineseName: transform(item.chineseName),
                            price: item.price,
                            originalDescription: item.originalDescription,
                            chineseDescription: item.chineseDescription.map(transform),
                            bbox: item.bbox,
                            photoBBox: item.photoBBox,
                            descriptionBBox: item.descriptionBBox,
                            descriptionLines: item.descriptionLines,
                            tags: item.tags,
                            recommendation: item.recommendation.map(transform)
                        )
                    }
                )
            },
            textLines: textLines?.map { line in
                TextLine(role: line.role, original: line.original,
                         translated: transform(line.translated), box: line.box)
            }
        )
    }
}
