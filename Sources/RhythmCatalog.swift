import Foundation

/// 作物/牲畜/鱼类的静态图鉴表（字面量单一事实源）。
/// 这里只放数据定义与按 id 的查找，数值平衡约束由冒烟测试守护。

struct CropDefinition: Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String
    let growthMinutes: Double
    let seedCost: Int
    let sellPrice: Int
    let level: Int

    var displayName: String { RhythmLocalization.text(name) }
}

struct AnimalDefinition: Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String
    let product: String
    let buyCost: Int
    let productValue: Int
    let level: Int

    var displayName: String { RhythmLocalization.text(name) }
    var displayProduct: String { RhythmLocalization.text(product) }
    var maturitySleepHours: Double { 6 + Double(level * 6) }
    var juvenileSellPrice: Int { max(1, Int((Double(buyCost) * 0.35).rounded(.down))) }
    var adultSellPrice: Int { max(1, Int((Double(buyCost) * 0.60).rounded(.down))) }
}

struct FishDefinition: Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String
    let sellPrice: Int
    let rarity: Int

    var displayName: String { RhythmLocalization.text(name) }
    var dailyIncome: Int {
        switch rarity {
        case 1: 1
        case 2: 1
        case 3: 2
        case 4: 3
        default: 5
        }
    }
}

/// 装饰贴图来源：全部复用现有图集，不新增美术素材。
/// 索引分别对应 CropAtlasV15（6×4）与 AnimalAtlasV23（6×4）的格子序号，鱼类用独立贴图。
enum DecorationSprite: Hashable {
    case crop(Int)
    case animal(Int)
    case fish(String)
}

struct DecorationDefinition: Identifiable, Hashable {
    let id: String
    let name: String
    let sprite: DecorationSprite
    /// 购买价（金币）。升级价 = basePrice × 2^当前等级，见 RhythmEconomy.decorationPrice。
    let basePrice: Int

    var displayName: String { RhythmLocalization.text(name) }
    /// 购买价（获得 level 1）。
    var purchasePrice: Int { RhythmEconomy.decorationPrice(base: basePrice, currentLevel: 0) }
    /// 从当前等级升到下一级所需金币。
    func upgradePrice(currentLevel: Int) -> Int {
        RhythmEconomy.decorationPrice(base: basePrice, currentLevel: currentLevel)
    }
}

enum RhythmCatalog {
    static let crops: [CropDefinition] = [
        .init(id: "carrot", name: "胡萝卜", emoji: "🥕", growthMinutes: 45, seedCost: 4, sellPrice: 7, level: 1),
        .init(id: "potato", name: "土豆", emoji: "🥔", growthMinutes: 60, seedCost: 5, sellPrice: 8, level: 1),
        .init(id: "wheat", name: "小麦", emoji: "🌾", growthMinutes: 75, seedCost: 6, sellPrice: 10, level: 1),
        .init(id: "corn", name: "玉米", emoji: "🌽", growthMinutes: 90, seedCost: 7, sellPrice: 11, level: 1),
        .init(id: "tomato", name: "番茄", emoji: "🍅", growthMinutes: 105, seedCost: 8, sellPrice: 13, level: 1),
        .init(id: "cabbage", name: "卷心菜", emoji: "🥬", growthMinutes: 120, seedCost: 10, sellPrice: 15, level: 2),
        .init(id: "cucumber", name: "黄瓜", emoji: "🥒", growthMinutes: 135, seedCost: 11, sellPrice: 17, level: 2),
        .init(id: "onion", name: "洋葱", emoji: "🧅", growthMinutes: 150, seedCost: 12, sellPrice: 18, level: 2),
        .init(id: "garlic", name: "大蒜", emoji: "🧄", growthMinutes: 165, seedCost: 13, sellPrice: 20, level: 2),
        .init(id: "pepper", name: "甜椒", emoji: "🫑", growthMinutes: 180, seedCost: 14, sellPrice: 22, level: 2),
        .init(id: "eggplant", name: "茄子", emoji: "🍆", growthMinutes: 195, seedCost: 15, sellPrice: 23, level: 2),
        .init(id: "broccoli", name: "西兰花", emoji: "🥦", growthMinutes: 210, seedCost: 16, sellPrice: 25, level: 2),
        .init(id: "peanut", name: "花生", emoji: "🥜", growthMinutes: 240, seedCost: 18, sellPrice: 28, level: 3),
        .init(id: "soybean", name: "大豆", emoji: "🫛", growthMinutes: 270, seedCost: 20, sellPrice: 31, level: 3),
        .init(id: "rice", name: "水稻", emoji: "🍚", growthMinutes: 300, seedCost: 22, sellPrice: 34, level: 3),
        .init(id: "strawberry", name: "草莓", emoji: "🍓", growthMinutes: 330, seedCost: 24, sellPrice: 37, level: 3),
        .init(id: "grape", name: "葡萄", emoji: "🍇", growthMinutes: 360, seedCost: 27, sellPrice: 41, level: 3),
        .init(id: "watermelon", name: "西瓜", emoji: "🍉", growthMinutes: 390, seedCost: 30, sellPrice: 45, level: 3),
        .init(id: "pumpkin", name: "南瓜", emoji: "🎃", growthMinutes: 450, seedCost: 34, sellPrice: 50, level: 4),
        .init(id: "sunflower", name: "向日葵", emoji: "🌻", growthMinutes: 510, seedCost: 38, sellPrice: 56, level: 4),
        .init(id: "tea", name: "茶树", emoji: "🍃", growthMinutes: 570, seedCost: 43, sellPrice: 63, level: 4),
        .init(id: "coffee", name: "咖啡树", emoji: "☕️", growthMinutes: 630, seedCost: 49, sellPrice: 71, level: 4),
        .init(id: "apple", name: "苹果树", emoji: "🍎", growthMinutes: 720, seedCost: 56, sellPrice: 81, level: 5),
        .init(id: "peach", name: "桃树", emoji: "🍑", growthMinutes: 840, seedCost: 64, sellPrice: 93, level: 5),
    ]

    static let animals: [AnimalDefinition] = [
        .init(id: "chicken", name: "母鸡", emoji: "🐔", product: "鸡蛋", buyCost: 35, productValue: 2, level: 1),
        .init(id: "duck", name: "鸭子", emoji: "🦆", product: "鸭蛋", buyCost: 42, productValue: 2, level: 1),
        .init(id: "goose", name: "鹅", emoji: "🪿", product: "鹅蛋", buyCost: 50, productValue: 3, level: 1),
        .init(id: "rabbit", name: "兔子", emoji: "🐇", product: "兔毛", buyCost: 58, productValue: 3, level: 1),
        .init(id: "quail", name: "鹌鹑", emoji: "🐦", product: "鹌鹑蛋", buyCost: 68, productValue: 4, level: 1),
        .init(id: "bee", name: "蜜蜂", emoji: "🐝", product: "蜂蜜", buyCost: 80, productValue: 4, level: 2),
        .init(id: "goat", name: "山羊", emoji: "🐐", product: "羊奶", buyCost: 92, productValue: 5, level: 2),
        .init(id: "sheep", name: "绵羊", emoji: "🐑", product: "羊毛", buyCost: 106, productValue: 5, level: 2),
        .init(id: "pig", name: "小猪", emoji: "🐖", product: "松露", buyCost: 122, productValue: 6, level: 2),
        .init(id: "cow", name: "奶牛", emoji: "🐄", product: "牛奶", buyCost: 140, productValue: 7, level: 2),
        .init(id: "silkworm", name: "蚕", emoji: "🐛", product: "蚕丝", buyCost: 160, productValue: 8, level: 3),
        .init(id: "turkey", name: "火鸡", emoji: "🦃", product: "火鸡羽", buyCost: 182, productValue: 9, level: 3),
        .init(id: "guineafowl", name: "珍珠鸡", emoji: "🐓", product: "花纹蛋", buyCost: 206, productValue: 10, level: 3),
        .init(id: "alpaca", name: "羊驼", emoji: "🦙", product: "驼绒", buyCost: 232, productValue: 11, level: 3),
        .init(id: "donkey", name: "毛驴", emoji: "🫏", product: "驴奶", buyCost: 260, productValue: 12, level: 3),
        .init(id: "deer", name: "梅花鹿", emoji: "🦌", product: "鹿茸", buyCost: 292, productValue: 13, level: 3),
        .init(id: "yak", name: "牦牛", emoji: "🐂", product: "牦牛奶", buyCost: 328, productValue: 15, level: 4),
        .init(id: "buffalo", name: "水牛", emoji: "🐃", product: "水牛奶", buyCost: 368, productValue: 17, level: 4),
        .init(id: "horse", name: "骏马", emoji: "🐎", product: "马鬃", buyCost: 412, productValue: 19, level: 4),
        .init(id: "ostrich", name: "鸵鸟", emoji: "🐦‍⬛", product: "鸵鸟蛋", buyCost: 460, productValue: 21, level: 4),
        .init(id: "peacock", name: "孔雀", emoji: "🦚", product: "孔雀羽", buyCost: 514, productValue: 24, level: 4),
        .init(id: "camel", name: "骆驼", emoji: "🐪", product: "骆驼奶", buyCost: 574, productValue: 27, level: 5),
        .init(id: "reindeer", name: "驯鹿", emoji: "🦌", product: "驯鹿绒", buyCost: 642, productValue: 30, level: 5),
        .init(id: "highlandcow", name: "高地牛", emoji: "🐮", product: "高地牛奶", buyCost: 720, productValue: 34, level: 5),
    ]

    static let fish: [FishDefinition] = [
        .init(id: "crucian", name: "鲫鱼", emoji: "🐟", sellPrice: 8, rarity: 1),
        .init(id: "carp", name: "鲤鱼", emoji: "🐟", sellPrice: 9, rarity: 1),
        .init(id: "grasscarp", name: "草鱼", emoji: "🐟", sellPrice: 10, rarity: 1),
        .init(id: "tilapia", name: "罗非鱼", emoji: "🐟", sellPrice: 11, rarity: 1),
        .init(id: "sardine", name: "沙丁鱼", emoji: "🐟", sellPrice: 12, rarity: 1),
        .init(id: "anchovy", name: "鳀鱼", emoji: "🐟", sellPrice: 13, rarity: 1),
        .init(id: "herring", name: "鲱鱼", emoji: "🐟", sellPrice: 14, rarity: 1),
        .init(id: "catfish", name: "鲶鱼", emoji: "🐟", sellPrice: 15, rarity: 1),
        .init(id: "bass", name: "鲈鱼", emoji: "🐠", sellPrice: 18, rarity: 2),
        .init(id: "mackerel", name: "鲭鱼", emoji: "🐟", sellPrice: 20, rarity: 2),
        .init(id: "trout", name: "鳟鱼", emoji: "🐟", sellPrice: 22, rarity: 2),
        .init(id: "snapper", name: "鲷鱼", emoji: "🐠", sellPrice: 24, rarity: 2),
        .init(id: "flounder", name: "比目鱼", emoji: "🐟", sellPrice: 26, rarity: 2),
        .init(id: "cod", name: "鳕鱼", emoji: "🐟", sellPrice: 28, rarity: 2),
        .init(id: "eel", name: "鳗鱼", emoji: "🐍", sellPrice: 30, rarity: 2),
        .init(id: "salmon", name: "三文鱼", emoji: "🐟", sellPrice: 32, rarity: 2),
        .init(id: "koi", name: "锦鲤", emoji: "🎏", sellPrice: 38, rarity: 3),
        .init(id: "tuna", name: "金枪鱼", emoji: "🐟", sellPrice: 42, rarity: 3),
        .init(id: "halibut", name: "大比目鱼", emoji: "🐟", sellPrice: 46, rarity: 3),
        .init(id: "puffer", name: "河豚", emoji: "🐡", sellPrice: 50, rarity: 3),
        .init(id: "angelfish", name: "神仙鱼", emoji: "🐠", sellPrice: 55, rarity: 3),
        .init(id: "betta", name: "斗鱼", emoji: "🐠", sellPrice: 60, rarity: 3),
        .init(id: "clownfish", name: "小丑鱼", emoji: "🐠", sellPrice: 66, rarity: 3),
        .init(id: "mahi", name: "鲯鳅", emoji: "🐟", sellPrice: 82, rarity: 4),
        .init(id: "sturgeon", name: "中华鲟", emoji: "🐟", sellPrice: 96, rarity: 4),
        .init(id: "swordfish", name: "剑鱼", emoji: "🐟", sellPrice: 112, rarity: 4),
        .init(id: "marlin", name: "旗鱼", emoji: "🐟", sellPrice: 132, rarity: 4),
        .init(id: "coelacanth", name: "腔棘鱼", emoji: "🐟", sellPrice: 180, rarity: 5),
    ]

    static func crop(_ id: String?) -> CropDefinition? {
        guard let id else { return nil }
        return crops.first { $0.id == id }
    }

    static func animal(_ id: String) -> AnimalDefinition? {
        animals.first { $0.id == id }
    }

    static func fish(_ id: String) -> FishDefinition? {
        fish.first { $0.id == id }
    }

    /// 庄园装饰表（12 种，购买价 200–2000 梯度；纯展示、无产出、升级无上限）。
    /// 贴图复用现有作物/动物/鱼类图集格子，索引务必与图鉴表顺序一致，由冒烟测试守护。
    static let decorations: [DecorationDefinition] = [
        .init(id: "wheat-sculpture", name: "金麦穗雕塑", sprite: .crop(2), basePrice: 200),
        .init(id: "carrot-windvane", name: "胡萝卜风向标", sprite: .crop(0), basePrice: 300),
        .init(id: "hen-planter", name: "母鸡花圃", sprite: .animal(0), basePrice: 400),
        .init(id: "pumpkin-lantern", name: "南瓜灯笼", sprite: .crop(18), basePrice: 500),
        .init(id: "sheep-fountain", name: "绵羊喷泉", sprite: .animal(7), basePrice: 650),
        .init(id: "sunflower-clock", name: "向日葵花钟", sprite: .crop(19), basePrice: 800),
        .init(id: "koi-fountain", name: "锦鲤喷泉", sprite: .fish("koi"), basePrice: 950),
        .init(id: "peacock-screen", name: "孔雀花屏", sprite: .animal(20), basePrice: 1100),
        .init(id: "horse-statue", name: "骏马铜像", sprite: .animal(18), basePrice: 1300),
        .init(id: "coelacanth-monument", name: "腔棘鱼水族碑", sprite: .fish("coelacanth"), basePrice: 1500),
        .init(id: "coffee-pavilion", name: "咖啡凉亭", sprite: .crop(21), basePrice: 1750),
        .init(id: "peach-archway", name: "桃树门廊", sprite: .crop(23), basePrice: 2000),
    ]

    static func decoration(_ id: String) -> DecorationDefinition? {
        decorations.first { $0.id == id }
    }
}
