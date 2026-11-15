"""作物、牲畜、鱼类、装饰与荒岛配方。数值与 Mac 版 RhythmCatalog / Catalog 一致。"""

from __future__ import annotations

SCHEMA_VERSION = 11
FOCUS_MINUTES_PER_COIN = 15
FOCUS_SESSION_COIN_CAP = 20
HABIT_REWARD_MIN = 1
HABIT_REWARD_MAX = 10
CHORE_COINS = 5
SHORT_ACTION_COINS = 8
SHORT_ACTION_BAIT = 1
LONG_GOAL_COINS = 60
LONG_GOAL_BAIT = 3
WATER_COST = 1
WATER_BOOST = 0.15
FERTILIZER_COST = 4
FERTILIZER_BOOST = 0.40
MAXIMUM_FOCUS_BOOST = 1.0
AQUARIUM_CAPACITY = 25
AQUARIUM_OFFLINE_DAY_CAP = 7
PLOT_CAP = 25
SHELTER_CAP = 25
MAX_FOCUS_DELTA_SECONDS = 8 * 3600
SLEEP_GROWTH_CAP_SECONDS = 14 * 3600
SLEEP_PRODUCTION_CYCLE_CAP = 2
REWARD_EVENT_CAP = 300

CHORE_COLORS = [
    "#EA8733", "#3373D1", "#2AAA8A", "#7B5CC6",
    "#D96186", "#4EAB68", "#637FE6", "#C79A32",
]

LEGACY_CROP_GROWTH_MINUTES = {
    "carrot": 25, "potato": 35, "wheat": 40, "corn": 50, "tomato": 60,
    "cabbage": 70, "cucumber": 75, "onion": 80, "garlic": 85, "pepper": 90,
    "eggplant": 95, "broccoli": 100, "peanut": 110, "soybean": 115, "rice": 120,
    "strawberry": 130, "grape": 140, "watermelon": 150, "pumpkin": 160,
    "sunflower": 170, "tea": 180, "coffee": 200, "apple": 220, "peach": 240,
}

# id, name, emoji, growth minutes, seed cost, sell price, level
CROPS = [
    ("carrot", "胡萝卜", "🥕", 45, 4, 7, 1),
    ("potato", "土豆", "🥔", 60, 5, 8, 1),
    ("wheat", "小麦", "🌾", 75, 6, 10, 1),
    ("corn", "玉米", "🌽", 90, 7, 11, 1),
    ("tomato", "番茄", "🍅", 105, 8, 13, 1),
    ("cabbage", "卷心菜", "🥬", 120, 10, 15, 2),
    ("cucumber", "黄瓜", "🥒", 135, 11, 17, 2),
    ("onion", "洋葱", "🧅", 150, 12, 18, 2),
    ("garlic", "大蒜", "🧄", 165, 13, 20, 2),
    ("pepper", "甜椒", "🫑", 180, 14, 22, 2),
    ("eggplant", "茄子", "🍆", 195, 15, 23, 2),
    ("broccoli", "西兰花", "🥦", 210, 16, 25, 2),
    ("peanut", "花生", "🥜", 240, 18, 28, 3),
    ("soybean", "大豆", "🫛", 270, 20, 31, 3),
    ("rice", "水稻", "🍚", 300, 22, 34, 3),
    ("strawberry", "草莓", "🍓", 330, 24, 37, 3),
    ("grape", "葡萄", "🍇", 360, 27, 41, 3),
    ("watermelon", "西瓜", "🍉", 390, 30, 45, 3),
    ("pumpkin", "南瓜", "🎃", 450, 34, 50, 4),
    ("sunflower", "向日葵", "🌻", 510, 38, 56, 4),
    ("tea", "茶树", "🍃", 570, 43, 63, 4),
    ("coffee", "咖啡树", "☕️", 630, 49, 71, 4),
    ("apple", "苹果树", "🍎", 720, 56, 81, 5),
    ("peach", "桃树", "🍑", 840, 64, 93, 5),
]

# id, name, emoji, product, buy, product value, level
ANIMALS = [
    ("chicken", "母鸡", "🐔", "鸡蛋", 35, 2, 1),
    ("duck", "鸭子", "🦆", "鸭蛋", 42, 2, 1),
    ("goose", "鹅", "🪿", "鹅蛋", 50, 3, 1),
    ("rabbit", "兔子", "🐇", "兔毛", 58, 3, 1),
    ("quail", "鹌鹑", "🐦", "鹌鹑蛋", 68, 4, 1),
    ("bee", "蜜蜂", "🐝", "蜂蜜", 80, 4, 2),
    ("goat", "山羊", "🐐", "羊奶", 92, 5, 2),
    ("sheep", "绵羊", "🐑", "羊毛", 106, 5, 2),
    ("pig", "小猪", "🐖", "松露", 122, 6, 2),
    ("cow", "奶牛", "🐄", "牛奶", 140, 7, 2),
    ("silkworm", "蚕", "🐛", "蚕丝", 160, 8, 3),
    ("turkey", "火鸡", "🦃", "火鸡羽", 182, 9, 3),
    ("guineafowl", "珍珠鸡", "🐓", "花纹蛋", 206, 10, 3),
    ("alpaca", "羊驼", "🦙", "驼绒", 232, 11, 3),
    ("donkey", "毛驴", "🫏", "驴奶", 260, 12, 3),
    ("deer", "梅花鹿", "🦌", "鹿茸", 292, 13, 3),
    ("yak", "牦牛", "🐂", "牦牛奶", 328, 15, 4),
    ("buffalo", "水牛", "🐃", "水牛奶", 368, 17, 4),
    ("horse", "骏马", "🐎", "马鬃", 412, 19, 4),
    ("ostrich", "鸵鸟", "🐦‍⬛", "鸵鸟蛋", 460, 21, 4),
    ("peacock", "孔雀", "🦚", "孔雀羽", 514, 24, 4),
    ("camel", "骆驼", "🐪", "骆驼奶", 574, 27, 5),
    ("reindeer", "驯鹿", "🦌", "驯鹿绒", 642, 30, 5),
    ("highlandcow", "高地牛", "🐮", "高地牛奶", 720, 34, 5),
]

# id, name, emoji, sell, rarity
FISH = [
    ("crucian", "鲫鱼", "🐟", 8, 1),
    ("carp", "鲤鱼", "🐟", 9, 1),
    ("grasscarp", "草鱼", "🐟", 10, 1),
    ("tilapia", "罗非鱼", "🐟", 11, 1),
    ("sardine", "沙丁鱼", "🐟", 12, 1),
    ("anchovy", "鳀鱼", "🐟", 13, 1),
    ("herring", "鲱鱼", "🐟", 14, 1),
    ("catfish", "鲶鱼", "🐟", 15, 1),
    ("bass", "鲈鱼", "🐠", 18, 2),
    ("mackerel", "鲭鱼", "🐟", 20, 2),
    ("trout", "鳟鱼", "🐟", 22, 2),
    ("snapper", "鲷鱼", "🐠", 24, 2),
    ("flounder", "比目鱼", "🐟", 26, 2),
    ("cod", "鳕鱼", "🐟", 28, 2),
    ("eel", "鳗鱼", "🐍", 30, 2),
    ("salmon", "三文鱼", "🐟", 32, 2),
    ("koi", "锦鲤", "🎏", 38, 3),
    ("tuna", "金枪鱼", "🐟", 42, 3),
    ("halibut", "大比目鱼", "🐟", 46, 3),
    ("puffer", "河豚", "🐡", 50, 3),
    ("angelfish", "神仙鱼", "🐠", 55, 3),
    ("betta", "斗鱼", "🐠", 60, 3),
    ("clownfish", "小丑鱼", "🐠", 66, 3),
    ("mahi", "鲯鳅", "🐟", 82, 4),
    ("sturgeon", "中华鲟", "🐟", 96, 4),
    ("swordfish", "剑鱼", "🐟", 112, 4),
    ("marlin", "旗鱼", "🐟", 132, 4),
    ("coelacanth", "腔棘鱼", "🐟", 180, 5),
]

# id, name, base price
DECORATIONS = [
    ("wheat-sculpture", "金麦穗雕塑", 200),
    ("carrot-windvane", "胡萝卜风向标", 300),
    ("hen-planter", "母鸡花圃", 400),
    ("pumpkin-lantern", "南瓜灯笼", 500),
    ("sheep-fountain", "绵羊喷泉", 650),
    ("sunflower-clock", "向日葵花钟", 800),
    ("koi-fountain", "锦鲤喷泉", 950),
    ("peacock-screen", "孔雀花屏", 1100),
    ("horse-statue", "骏马铜像", 1300),
    ("coelacanth-monument", "腔棘鱼水族碑", 1500),
    ("coffee-pavilion", "咖啡凉亭", 1750),
    ("peach-archway", "桃树门廊", 2000),
]

ISLAND_MATERIALS = ["wood", "stone", "fiber", "ration", "iron", "herb"]
ISLAND_LEVEL_MARKS = [0, 20, 60, 100, 140, 190, 260, 340, 430, 520]
ISLAND_EXPANSION_COSTS = [
    {"wood": 35, "stone": 20, "fiber": 12},
    {"wood": 70, "stone": 45, "iron": 20},
    {"wood": 120, "stone": 80, "iron": 40, "herb": 20},
]
ISLAND_EXPANSION_REQUIREMENTS = [100, 240, 370]
ISLAND_DEFAULT_SITES = {
    "campfire": (-1.7, 0.7), "shelter": (1.1, -1.1), "well": (2.8, 0.7),
    "garden": (-3.4, -1.9), "farm": (3.5, -2.2), "herbGarden": (-1.3, -3),
    "clinic": (3.2, 3), "training": (-3.6, 2.7),
    "rainCollector": (0, 3.8), "orchard": (5.4, 0),
    "workshop": (-4.9, 0.6), "windmill": (-4.9, -3.5),
    "kitchen": (0, -5.2), "teaHouse": (1.1, 5.6),
}

# id, cn, cost, prerequisite, tool, minimum expansion
ISLAND_RECIPES = [
    ("campfire", "篝火", {"wood": 6, "stone": 2}, None, False, 0),
    ("shelter", "木棚", {"wood": 12, "fiber": 6}, None, False, 0),
    ("well", "水井", {"wood": 6, "stone": 8, "fiber": 4}, "pickaxe", False, 0),
    ("garden", "菜园", {"wood": 8, "fiber": 4}, None, False, 0),
    ("farm", "农田", {"wood": 20, "stone": 10, "fiber": 8}, "garden", False, 0),
    ("herbGarden", "药圃", {"wood": 6, "stone": 2, "fiber": 4}, None, False, 0),
    ("clinic", "医馆", {"wood": 15, "stone": 12, "herb": 5}, "herbGarden", False, 0),
    ("training", "训练场", {"wood": 12, "stone": 8}, None, False, 0),
    ("rainCollector", "雨水收集站", {"wood": 16, "stone": 10, "fiber": 8}, None, False, 0),
    ("orchard", "果园", {"wood": 24, "fiber": 14, "ration": 6}, "garden", False, 1),
    ("workshop", "工坊", {"wood": 30, "stone": 20, "iron": 5}, "pickaxe", False, 1),
    ("windmill", "风车", {"wood": 30, "stone": 25, "iron": 8}, "workshop", False, 2),
    ("kitchen", "厨房", {"wood": 20, "stone": 30, "iron": 6}, "campfire", False, 1),
    ("teaHouse", "茶亭", {"wood": 28, "stone": 12, "fiber": 15, "herb": 8}, "herbGarden", False, 2),
    ("axe", "石斧", {"wood": 3, "stone": 2, "fiber": 2}, None, True, 0),
    ("pickaxe", "石镐", {"wood": 3, "stone": 3, "fiber": 2}, None, True, 0),
    ("spear", "鱼叉", {"wood": 4, "fiber": 3}, None, True, 0),
    ("ironAxe", "铁斧", {"wood": 5, "iron": 4, "fiber": 3}, None, True, 0),
    ("ironPickaxe", "铁镐", {"wood": 4, "iron": 5}, None, True, 0),
    ("net", "渔网", {"wood": 6, "fiber": 10}, None, True, 0),
]

# id, cn, energy, food, water, output, quantity, need
ISLAND_ACTIONS = [
    ("chop", "砍树", 8, 5, 0, "wood", 3, None),
    ("fiber", "割藤采麻", 5, 0, 0, "fiber", 3, None),
    ("pebble", "敲碎石", 6, 0, 0, "stone", 1, None),
    ("quarry", "采石", 10, 6, 0, "stone", 4, "pickaxe"),
    ("mine", "挖矿", 12, 6, 0, "iron", 2, "pickaxe"),
    ("fish", "叉鱼", 6, 0, 3, "ration", 2, "campfire"),
    ("coconut", "采椰摘果", 4, 0, 0, "ration", 1, None),
    ("herb", "采药", 6, 0, 0, "herb", 2, "herbGarden"),
]

TRAIN_CARRIAGES = {
    "sleeper": "卧铺车",
    "dining": "餐车",
    "observation": "观景车",
    "garden": "花园车",
    "library": "书房车",
}
TRAIN_UPGRADE_COSTS = [6, 12, 20, 30]

EVENT_COLORS = ["blue", "teal", "orange", "purple", "pink", "green"]
EVENT_SYMBOLS = [
    "cup.and.saucer.fill", "mug.fill", "waterbottle.fill", "brain.head.profile",
    "toilet.fill", "pills.fill", "heart.fill", "moon.fill", "figure.walk", "checkmark.circle",
]
DEFAULT_EVENT_TYPES = [
    ("C21F813B-465B-4835-942F-000000000001", "喝饮料", "Soft drink", "waterbottle.fill", "blue"),
    ("C21F813B-465B-4835-942F-000000000002", "喝奶茶", "Milk tea", "mug.fill", "orange"),
    ("C21F813B-465B-4835-942F-000000000003", "喝咖啡", "Coffee", "cup.and.saucer.fill", "teal"),
    ("C21F813B-465B-4835-942F-000000000004", "头疼", "Headache", "brain.head.profile", "purple"),
    ("C21F813B-465B-4835-942F-000000000005", "拉屎", "Bowel movement", "toilet.fill", "green"),
]

MATERIAL_NAMES = {
    "wood": "木材", "stone": "石材", "fiber": "纤维",
    "ration": "干粮", "iron": "铁矿", "herb": "药材",
}


def _index(rows, key_index=0):
    return {row[key_index]: row for row in rows}


CROPS_BY_ID = _index(CROPS)
ANIMALS_BY_ID = _index(ANIMALS)
FISH_BY_ID = _index(FISH)
DECORATIONS_BY_ID = _index(DECORATIONS)
RECIPES_BY_ID = _index(ISLAND_RECIPES)
ACTIONS_BY_ID = _index(ISLAND_ACTIONS)


def crop(crop_id):
    return CROPS_BY_ID.get(crop_id)


def animal(animal_id):
    return ANIMALS_BY_ID.get(animal_id)


def fish(fish_id):
    return FISH_BY_ID.get(fish_id)


def decoration(definition_id):
    return DECORATIONS_BY_ID.get(definition_id)


def maturity_hours(level: int) -> float:
    return 6 + level * 6


def juvenile_price(buy_cost: int) -> int:
    return max(1, int(buy_cost * 0.35))


def adult_price(buy_cost: int) -> int:
    return max(1, int(buy_cost * 0.60))


def decoration_price(base: int, current_level: int) -> int:
    shift = max(0, min(current_level, 40))
    return base << shift


def farm_plot_cost(existing_count: int) -> int:
    expansions = max(0, existing_count - 1)
    return 50 + expansions * 18 + expansions * expansions * 2


def animal_shelter_cost(existing_capacity: int) -> int:
    expansions = max(0, existing_capacity - 1)
    return 70 + expansions * 22 + expansions * expansions * 3


def fishing_rarity(roll: int) -> int:
    roll = min(100, max(1, roll))
    if roll == 1:
        return 5
    if 2 <= roll <= 5:
        return 4
    if 6 <= roll <= 17:
        return 3
    if 18 <= roll <= 45:
        return 2
    return 1


def fish_of_rarity(rarity: int):
    return [row for row in FISH if row[4] == rarity]


def daily_income(rarity: int) -> int:
    if rarity <= 2:
        return 1
    if rarity == 3:
        return 2
    if rarity == 4:
        return 3
    return 5


def train_upgrade_cost(next_level: int) -> int:
    index = min(max(next_level, 1), 4) - 1
    return TRAIN_UPGRADE_COSTS[index]
