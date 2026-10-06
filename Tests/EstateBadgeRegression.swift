import AppKit
import SceneKit
@main struct EstateRender {
    static func main() {
        _ = NSApplication.shared
        let cropIDs=["carrot","potato","wheat","corn","tomato","cabbage","cucumber","onion","garlic","pepper","eggplant","broccoli","peanut","soybean","rice","strawberry","grape","watermelon","pumpkin","sunflower","tea","coffee","apple","peach"]
        let animalIDs=["chicken","duck","goose","rabbit","quail","bee","goat","sheep","pig","cow","silkworm","turkey","guineafowl","alpaca","donkey","deer","yak","buffalo","horse","ostrich","peacock","camel","reindeer","highlandcow"]
        for mode in ["farm","pasture"] {
            var items:[GQWorldItem]=[]
            if mode == "farm" || mode == "pasture" {
                for i in 0..<24 {
                    items.append(GQWorldItem(id:"\(i)",title:mode == "farm" ? ["胡萝卜","土豆","小麦","玉米","番茄","白菜"][i%6] : ["鸡","鸭","鹅","兔","羊","牛"][i%6],kind:mode == "farm" ? "crop:\(cropIDs[i])" : "animal:\(animalIDs[i])",level:i%3+1,x:Double(i%5-2)*2.12,z:Double(i/5-2)*2.45,movable:false,progress:Double(i%10)/10,status:"生长 \(i%10*10)%"))
                }
            } else if mode == "fishing" { items=[GQWorldItem(id:"bobber",title:"",kind:"bobber",level:3,x:2,z:0.8,movable:false)] }
            else {
                for (i,id) in ["goldfish","carp","salmon","tuna","clownfish"].enumerated() { items.append(GQWorldItem(id:"resident\(i)",title:"鱼",kind:"fish:\(id)",level:2,x:Double(i-2)*3,z:0,movable:false)) }
            }
            items.append(GQWorldItem(id:"expansion",title:mode == "farm" ? "开垦" : "扩建",kind:"unlock",level:0,x:4.24,z:4.9,movable:false,status:"2300 金币"))
            let scene=GQWorldBuilder.scene(mode:mode,items:items,selectedID:nil)
            for item in items where mode == "farm" || mode == "pasture" {
                let node=scene.rootNode.childNode(withName:"item:\(item.id)",recursively:true)!
                node.removeAllActions()
                GQWorldBuilder.estateBadge(node,item:item,mode:mode)
                let before=node.childNode(withName:"estate-badge",recursively:true)!.position
                GQWorldBuilder.estateBadge(node,item:item,mode:mode)
                let after=node.childNode(withName:"estate-badge",recursively:true)!.position
                assert(before.y == after.y && abs(after.y-1.18)<0.001)
                if let holder=node.childNode(withName:"estate-specimen",recursively:false), let body=holder.childNodes.first(where:{$0.name != "estate-badge"}), let plane=body.geometry as? SCNPlane {
                    assert(body.position.y+plane.height/2 < after.y-0.55/2, "Badge must clear the entire visible specimen")
                    assert(after.y+0.55/2 < 2.45*24/sqrt(24*24+17*17), "Unit must fit its projected row")
                }
                assert((node.childNode(withName:"estate-badge",recursively:true)!.geometry as! SCNPlane).height == 0.55)
            }
            let camera=scene.rootNode.childNode(withName:"camera",recursively:false)!
            camera.position=mode == "aquarium" ? SCNVector3(0,4,20) : SCNVector3(0,mode == "fishing" ? 13 : 24,17)
            camera.look(at:mode == "aquarium" ? SCNVector3(0,4,0) : SCNVector3(0,0,0))
            camera.camera?.orthographicScale=mode == "aquarium" ? 5.9 : mode == "fishing" ? 8.2 : 7.6
            let renderer=SCNRenderer(device:nil,options:nil); renderer.scene=scene; renderer.pointOfView=camera
            renderer.update(atTime:0);renderer.update(atTime:1)
            let image=renderer.snapshot(atTime:1,with:CGSize(width:1400,height:788),antialiasingMode:.multisampling4X)
            let data=NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
            try! data.write(to:URL(fileURLWithPath:"/tmp/gq357-preview-\(mode).png"))
            print("Rendered \(mode)")
        }
    }
}
