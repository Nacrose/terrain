extends SceneTree
const Terrain = preload("res://addons/stoem_terrain/nodes/terrain_3d.gd")
func _initialize():
    run.call_deferred()
func run():
    var t = Terrain.new()
    root.add_child(t)
    t.bake()
    t.enable_collision = true
    print("body=", t._collision_body, " world=", t.get_world_3d(), " enabled=", t.enable_collision)
    var boxbody = StaticBody3D.new()
    var boxshape = CollisionShape3D.new()
    boxshape.shape = BoxShape3D.new()
    boxbody.add_child(boxshape)
    boxbody.position = Vector3(0, 100, 0)
    root.add_child(boxbody)
    var points = [Vector2(-96,-96), Vector2(-0.01,-96), Vector2(0,0), Vector2(20,10)]
    for p in points:
        var i = roundi(p.x+384) + roundi(p.y+384)*769
        print("point=",p," height=",t.height_at(p)," shape=",t._ground_shapes[clampi((roundi(p.x+384)/48)+ (roundi(p.y+384)/48)*16,0,255)].shape)
    await physics_frame
    await physics_frame
    for sh in t._ground_shapes:
        sh.shape.backface_collision = true
    var sf = t._ground_shapes[136].shape.get_faces()
    print("faces size=",sf.size()," sample=",sf.slice(0,6)," body layer=",t._collision_body.collision_layer," transform=",t._collision_body.global_transform)
    var boxq = PhysicsRayQueryParameters3D.create(Vector3(0,110,0), Vector3(0,90,0))
    print("box ray=", t.get_world_3d().direct_space_state.intersect_ray(boxq), " body_inside=", t._collision_body.is_inside_tree(), " shape_disabled=", t._ground_shapes[0].disabled)
    for p in points:
        var h=t.height_at(p)
        var q=PhysicsRayQueryParameters3D.create(Vector3(p.x,h+10,p.y),Vector3(p.x,h-10,p.y))
        q.hit_back_faces = true
        print("ray ",p," -> ",t.get_world_3d().direct_space_state.intersect_ray(q))
    quit()
