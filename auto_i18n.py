from glob import glob
import json

files = glob("**/*.json")
langs = ["en", "en-tts","fr","ja","zh"]

for file in files:
    # read file
    with open(file,"r") as f:
        i18n = json.load(f)
    
    #stub with en
    for menu_item, translations in i18n.items():
        for lang in langs:
            if not lang in translations:
                translations[lang] = f"{translations['en']} *EN*"
    # write file 
    with open(file,"w") as f:
        json.dump(i18n,f,ensure_ascii=False,check_circular=False,sort_keys=True,indent=4)
     
