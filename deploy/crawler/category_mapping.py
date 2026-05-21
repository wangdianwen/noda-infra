"""
category_mapping.py - 分类映射模块

从 db_import.py 提取，供 llm_extract.py 和其他模块使用。
"""

CATEGORY_KEYWORDS = {
    # 音乐艺术
    'music-piano': ['钢琴', '琴', '键盘'],
    'music-instruments': ['小提琴', '吉他', '古筝', '管乐', '弦乐', '管乐器', '弦乐器', '大提琴', '中提琴', '长笛', '萨克斯', '单簧管'],
    'music-vocal': ['声乐', '歌唱', '合唱', '音乐理论', '乐理', '视唱练耳', '指挥', '音乐', '乐器', '表演'],

    # 学科辅导
    'academic-math': ['数学', '微积分', '统计', '奥数', '心算', '算术', '代数', '几何'],
    'academic-english': ['英语', '英文', '雅思', '托福', 'ESOL', 'PTE', '英文写作', '阅读', '写作'],
    'academic-science': ['物理', '化学', '生物', '科学', '理科', '综合科学'],
    'academic-business': ['商科', '会计', '经济', '金融', 'NCEA商科', '商业', '商法', '信息系统'],

    # 美术设计
    'arts-painting': ['绘画', '素描', '水彩', '油画', '创意画', '美术', '画画', '速写', '艺术'],
    'arts-digital-art': ['平面设计', '插画', '数字艺术', 'UI设计', '设计', 'Photoshop', 'Illustrator', '摄影'],
    'arts-calligraphy': ['书法', '国画', '毛笔', '水墨', '硬笔书法'],

    # 语言学习
    'language-chinese': ['中文', '国语', '国学', '文学', '汉语', '创意写作', '阅读理解', '沟通'],
    'language-other-languages': ['日语', '韩语', '粤语', '西班牙语', '法语', '德语', '外语', '意大利语'],

    # 体育健身
    'sports-fitness': ['瑜伽', '体育健身', '普拉提', '健身', '体能训练', '有氧', '健身房', '体育', '体育培训', '艺术体操'],
    'sports-swimming': ['游泳', '水上运动', '蛙泳', '自由泳', '仰泳', '蝶泳'],
    'sports-ball-games': ['足球', '篮球', '网球', '羽毛球', '乒乓球', '球类', '排球', '橄榄球', '棒球'],

    # 舞蹈表演
    'dance-dance': ['舞蹈', '舞蹈基础', '舞蹈艺术', '形体舞蹈', '中国舞', '当代舞', '民族舞'],
    'dance-ballet': ['芭蕾', '形体训练', '芭蕾舞'],
    'dance-street-dance': ['爵士舞', '韩舞', '街舞', 'Hip-Hop', '流行舞', 'K-Pop', 'Breaking', 'Locking'],

    # 技能培训
    'skills-driving': ['驾照', '驾驶', '驾照考试', '驾驶培训'],
    'skills-vocational': ['叉车', '建筑', '职业', '技能培训', '职业培训', '焊工', '电工', '法律'],
    'skills-life-skills': ['咖啡', '烘焙', '手工', '生活技能', '手工艺术', '烹饪', '厨艺', '美容按摩', '按摩', '语言沟通', '学校事务'],
}


def map_subject_to_categories(subject):
    """将科目字符串映射到分类 slug 列表"""
    if not subject or not subject.strip():
        return ['other-other']

    matched = []
    subject_lower = subject.lower()

    for category_slug, keywords in CATEGORY_KEYWORDS.items():
        for keyword in keywords:
            if keyword.lower() in subject_lower:
                if category_slug not in matched:
                    matched.append(category_slug)
                break

    return matched if matched else ['other-other']
