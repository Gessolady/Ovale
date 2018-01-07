import { OvaleScripts } from "../Scripts";
export function register() {
    let name = "ovale_hunter_spells";
    let desc = "[7.0] Ovale: Hunter spells";
    let code = `
# Hunter spells and functions.

Define(a_murder_of_crows 131894)
	SpellInfo(a_murder_of_crows cd=60 focus=30)
Define(a_murder_of_crows_debuff 131894)
Define(aimed_shot 19434)
	SpellInfo(aimed_shot focus=50)
	SpellRequire(aimed_shot focus_percent 0=buff,lock_and_load_buff talent=lock_and_load_talent)
	SpellAddBuff(aimed_shot lock_and_load_buff=-1 talent=lock_and_load_talent)
Define(animal_instincts_talent 1)
Define(arcane_shot 185358)
	SpellInfo(arcane_shot focus=-5)
	SpellAddBuff(arcane_shot marking_targets_buff=-1)
	SpellInfo(arcane_shot replace=sidewinders talent=sidewinders_talent)
	# TODO: Following line's if statements don't work?
	#SpellAddTargetDebuff(arcane_shot hunters_mark_debuff=1 if_buff=marking_targets_buff)
	#SpellAddTargetDebuff(arcane_shot hunters_mark_debuff=1 if_buff=trueshot_buff)
Define(aspect_of_the_eagle 186289)
	SpellInfo(aspect_of_the_eagle cd=120 gcd=0 offgcd=1)
	SpellAddBuff(aspect_of_the_eagle aspect_of_the_eagle_buff=1)
Define(aspect_of_the_eagle_buff 186289)
	SpellInfo(aspect_of_the_eagle_buff duration=10)
Define(aspect_of_the_wild 193530)
	SpellInfo(aspect_of_the_wild cd=120 gcd=0 offgcd=1)
Define(aspect_of_the_wild_buff 193530)
	SpellInfo(aspect_of_the_wild_buff duration=10)
Define(barrage 120360)
	SpellInfo(barrage cd=20 focus=60)
Define(bestial_wrath 19574)
	SpellInfo(bestial_wrath cd=60 gcd=0 offgcd=1)
	SpellAddBuff(bestial_wrath bestial_wrath_buff=1)
Define(bestial_wrath_buff 19574)
	SpellInfo(bestial_wrath_buff duration=15)
Define(black_arrow 194599)
	SpellInfo(black_arrow cd=15 cd_haste=ranged focus=40)
	SpellAddTargetDebuff(black_arrow black_arrow_debuff=1)
Define(black_arrow_debuff 194599)
	SpellInfo(black_arrow_debuff duration=8 tick=2)
Define(bullseye 204089)
Define(bullseye_buff 204089)
Define(bursting_shot 186387)
	SpellInfo(bursting_shot cd=30 focus=10)
Define(butchery 212436)
	SpellInfo(butchery focus=40 cd=15 cd_haste=ranged)
Define(caltrops 194277)
	SpellInfo(caltrops cd=15)
Define(caltrops_debuff 194279)
Define(carve 187708)
	SpellInfo(carve focus=40)
	SpellAddTargetDebuff(carve serpent_sting_debuff=1 talent=serpent_sting_talent)
Define(chimaera_shot 53209)
	SpellInfo(chimaera_shot focus=-10 cd=15 cd_haste=ranged)
Define(cobra_shot 193455)
	SpellInfo(cobra_shot focus=40)
Define(counter_shot 147362)
	SpellInfo(counter_shot cd=24)
Define(dire_beast 120679)
	SpellInfo(dire_beast cd=12 cd_haste=ranged charges=2)
	SpellInfo(dire_beast charges=3 if_equipped=the_mantle_of_command)
	SpellAddPetBuff(dire_beast dire_beast_buff=1)
Define(dire_beast_buff 120679)
	SpellInfo(dire_beast_buff duration=8)
	SpellInfo(dire_beast unusable=1 talent=dire_frenzy_talent)
	# TODO: Regenerates 3 focus every 2 seconds, double for dire_stable_talent
Define(dire_frenzy 217200)
	SpellInfo(dire_frenzy cd=12 focus=-25 charges=2)
	SpellInfo(dire_frenzy charges=3 if_equipped=the_mantle_of_command)
	SpellInfo(dire_frenzy focus=-37 talent=dire_stable_talent)
	SpellAddPetBuff(dire_frenzy dire_frenzy_buff=1)
Define(dire_frenzy_buff 217200)
	SpellInfo(dire_frenzy_buff duration=8 max_stacks=3)
Define(dragonsfire_grenade 194855)
	SpellInfo(dragonsfire_grenade cd=30)
Define(explosive_shot 212431)
	SpellInfo(explosive_shot cd=30)
Define(explosive_shot_detonate 212679)
Define(explosive_trap 191433)
	SpellInfo(explosive_trap cd=30)
	SpellInfo(explosive_trap add_cd=-20 if_spell=enhanced_traps)
Define(explosive_trap_debuff 13812)
	SpellInfo(explosive_trap_debuff duration=20 tick=2)
Define(flanking_strike 202800)
	SpellInfo(flanking_strike cd=6 focus=50)
Define(frizzos_fingertrap 137043)
Define(fury_of_the_eagle 203415)
	SpellInfo(fury_of_the_eagle cd=45)
Define(fury_of_the_eagle_debuff 203415) #TODO Does not seem to exist
Define(harpoon 190925)
	SpellInfo(harpoon cd=20)
Define(heart_of_the_phoenix 55709)
	SpellInfo(heart_of_the_phoenix cd=480)
Define(heart_of_the_phoenix_debuff 55711)
	SpellInfo(heart_of_the_phoenix_debuff duration=480)
Define(hunters_mark_debuff 185365)
	SpellInfo(hunters_mark_debuff duration=12)
Define(kill_command 34026)
	SpellInfo(kill_command cd=7.5 cd_haste=ranged focus=30)
	# Unsure of right syntax for following line.  
	# cobra_shot resets kill_command upon impact with the target when bestial_wrath_buff is up
	# SpellRequire(kill_command cd_percent 0=spell,cobra_shot if_buff=bestial_wrath_buff)
Define(lacerate 185855)
	SpellInfo(lacerate focus=35 cd=10)
	SpellAddTargetDebuff(lacerate lacerate_debuff=1)
Define(lacerate_debuff 185855)
Define(lock_and_load_buff 194594)
Define(marked_shot 185901)
	SpellInfo(marked_shot focus=30)
	SpellAddBuff(marked_shot vulnerable=1)
	SpellAddTargetDebuff(marked_shot hunters_mark_debuff=-1)
	SpellRequire(marked_shot unusable 1=target_debuff,!hunters_mark_debuff)
Define(marking_targets_buff 223138)
	SpellInfo(marking_targets_buff duration=10)
Define(moknathal_tactics_buff 201081)
	SpellInfo(moknathal_tactics_buffs duration=8)
Define(mongoose_bite 190928)
	SpellInfo(mongoose_bite cd=12)
Define(mongoose_fury_buff 190931)
	SpellInfo(mongoose_fury_buff duration=12)
Define(multi_shot 2643)
Define(multishot 2643)
	SpellInfo(multishot focus=40 specialization=beast_mastery)
	# TODO: Following line's if statements don't work?
	#SpellAddTargetDebuff(multishot hunters_mark_debuff=1 if_buff=marking_targets_buff)
	#SpellAddTargetDebuff(multishot hunters_mark_debuff=1 if_buff=trueshot_buff)
	# TODO: 2 focus per target hit, estimate with tagged enemies?
	SpellInfo(multishot focus=-2 specialization=marksman)
	SpellAddBuff(multishot marking_targets_buff-1 specialization=marksman)
Define(muzzle 187707)
	SpellInfo(muzzle cd=15)
Define(pet_beast_cleave_buff 118455)
Define(pet_dire_frenzy_buff 217200)
Define(piercing_shot 198670)
	SpellInfo(piercing_shot cd=30 focus=20)
Define(raptor_strike 186270)
	SpellInfo(raptor_strike focus=25)
	SpellAddTargetDebuff(raptor_strike serpent_sting_debuff=1 talent=serpent_sting_talent)
Define(revive_pet 982)
	SpellInfo(revive_pet focus=35)
Define(sentinel 206817)
	SpellInfo(sentinel cd=30 charges=2)
	SpellAddTargetDebuff(sentinel hunters_mark_debuff=1)
Define(sentinel_talent 11)
Define(sentinels_sight_buff 208913)
Define(serpent_sting_debuff 118253)
Define(sidewinders 214579)
	SpellInfo(sidewinders focus=-50 cd=12 cd_haste=ranged)
Define(snake_hunter 201078)
	SpellInfo(snake_hunter cd=90)
	#TODO Add 3 charges of mongoose_bite
Define(spitting_cobra 194407)
	SpellInfo(spitting_cobra cd=60)
	SpellAddBuff(spitting_cobra spitting_cobra_buff)
Define(spitting_cobra_buff 194407)
	SpellInfo(spitting_cobra_buff duration=30)
Define(stampede 201430)
	SpellInfo(stampede cd=180)
Define(steady_focus_buff 193534)
	SpellInfo(steady_focus_buff duration=12)
Define(steel_trap 162488)
	SpellInfo(steel_trap cd=60)
Define(the_mantle_of_command 144326)
Define(throwing_axes 200163)
	SpellInfo(throwing_axes focus=15 cd=15)
Define(titans_thunder 207068)
	SpellInfo(titans_thunder cd=60)
Define(titans_thunder_tick 207097)
Define(trap_launcher 77769)
	SpellInfo(trap_launcher cd=1.5)
Define(true_aim_debuff 199803)
	SpellInfo(true_aim_debuff max_stacks=8)
Define(trueshot 193526)
	SpellInfo(trueshot cd=180)
	SpellAddBuff(trueshot trueshot_buff=1)
Define(trueshot_buff 193526)
	SpellInfo(trueshot_buff duration=15)
Define(volley 194386)
	SpellInfo(volley cd=1.5)
	SpellAddBuff(volley volley_buff=1)
	SpellRequire(volley unusable 1=buff,volley_buff)
Define(volley_buff 194386)
Define(vulnerable 187131)
	SpellInfo(vulnerable duration=30)
Define(vulnerability_debuff 187131)
	SpellInfo(vulnerability_debuff duration=30)
Define(way_of_the_moknathal_talent 3)
Define(windburst 204147)
	SpellInfo(windburst focus=20 cd=20)

# Talents
Define(barrage_talent 17)
Define(lone_wolf_talent 1)
Define(steady_focus_talent 2)
Define(throwing_axes_talent 2)	
Define(dire_stable_talent 3)
Define(careful_aim_talent 3)
Define(lock_and_load_talent 4)
Define(dire_frenzy_talent 5)
Define(true_aim_talent 6)
Define(patient_sniper_talent 12)
Define(a_murder_of_crows_talent 16)
Define(serpent_sting_talent 18)
Define(stampede_talent 19)
Define(sidewinders_talent 19)
Define(killer_cobra_talent 20)
Define(piercing_shot_talent 20)
Define(trick_shot_talent 21)
Define(spitting_cobra_talent 19)
Define(one_with_the_pack_talent 10)

# Legendary items
Define(qapla_eredun_war_order 137227)
Define(call_of_the_wild 137101)
Define(parsels_tongue 151805)
Define(parsels_tongue_buff 248085)

# Item set
Define(t20_2p_critical_aimed_damage_buff 242242) # TODO

# Non-default tags for OvaleSimulationCraft.
SpellInfo(dire_beast tag=main)
SpellInfo(dire_frenzy tag=main)
SpellInfo(barrage tag=shortcd)

`;
    OvaleScripts.RegisterScript("HUNTER", undefined, name, desc, code, "include");
}
